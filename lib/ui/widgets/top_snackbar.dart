import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// Handle returned by [showTopSnackBar].
///
/// Replaces the previous `ScaffoldFeatureController<SnackBar, …>` so
/// the same call works whether we render a Material SnackBar (mobile)
/// or push to the IntelliJ-style notification center (desktop).
/// Callers that just want fire-and-forget can ignore it; callers that
/// need to know when the toast disappeared (e.g. the close-tab undo
/// flow) can `await handle.closed`.
class SnackBarHandle {
  SnackBarHandle(this.closed);

  /// Resolves when the toast / notification has dismissed for any
  /// reason - auto-dismiss, manual swipe, or action tap.  We don't
  /// distinguish reasons because no current caller cares; the old
  /// `SnackBarClosedReason` enum was always treated as "it's gone now,
  /// run the cleanup".
  final Future<void> closed;
}

/// Show a top-positioned in-app message.
///
/// **Desktop** (Windows / macOS / Linux): renders as an IntelliJ-style
/// toast in the notification center - slides in from the right, lives
/// in the bell history, dismisses on a click rather than a weird
/// pull-to-close gesture.
///
/// **Mobile** (Android / iOS): renders as a Material SnackBar pinned
/// to the top of the screen.  Swipe **up** dismisses it (the previous
/// implementation had snackbars at the top but only swiping DOWN
/// dismissed them, which is the opposite of every user's instinct).
///
/// **Severity flags** (`isError` / `isWarning` / `isInfo` /
/// `isSuccess`) tint the background and prepend a matching icon.
/// Apply at most one - when multiple are set the precedence order
/// listed above wins.
///
/// **Width**: ignored on desktop (notifications have their own width).
/// On mobile, when null the snackbar spans the visible width minus
/// 16px left/right padding; pass an explicit `width` for a fixed-size
/// centred toast.
///
/// **Details**: what stands behind an error (the exception as the system
/// gave it, what a server answered). It is not shown; the message gets a
/// "Copy details" beside it, which copies the report [ErrorReport.build]
/// makes of the failure: the message, the details, which app and system
/// this is and the last lines the app logged, with every name and secret
/// taken out. An action of the caller's own stands beside it.
///
/// **Duration**: how long it stays where it closes by itself (on a
/// computer an error stays until it is closed). Left out, a plain message
/// stays [kToastDuration]; an error stays long enough to be read, and
/// longer still where there is something to tap.
SnackBarHandle showTopSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  bool isError = false,
  bool isWarning = false,
  bool isInfo = false,
  bool isSuccess = false,
  String? actionLabel,
  VoidCallback? onAction,
  String? details,
  double? width,
}) {
  // Every error has its report and Copy details, with what the caller knows
  // of it where there is anything: an error with no details had no copy
  // button and its words could not be selected, so nothing of it reached
  // support but a sentence to retype.
  final hasDetails = details != null && details.trim().isNotEmpty;
  final report = hasDetails || isError ? ErrorReport.build(what: message, details: hasDetails ? details : null) : null;
  final stays = duration ??
      toastDurationFor(
          isError: isError, tappable: report != null || (actionLabel != null && onAction != null), message: message);
  if (!(debugTopSnackBarOnPhone ?? !isDesktopPlatform)) {
    return _showDesktopNotification(
      context: context,
      message: message,
      duration: stays,
      isError: isError,
      isWarning: isWarning,
      isInfo: isInfo,
      isSuccess: isSuccess,
      actionLabel: actionLabel,
      onAction: onAction,
      details: report,
    );
  }
  return _showMobileSnackBar(
    context: context,
    message: message,
    duration: stays,
    isError: isError,
    isWarning: isWarning,
    isInfo: isInfo,
    isSuccess: isSuccess,
    actionLabel: actionLabel,
    onAction: onAction,
    details: report,
    width: width,
  );
}

/// A test's word on whether a phone shows the message (a card at the top
/// of the screen) or a computer does (the notification center). Null asks
/// the system the app runs on.
@visibleForTesting
bool? debugTopSnackBarOnPhone;

/// The least a message stays that nobody set a time for.
const Duration kToastDuration = Duration(seconds: 3);

/// How long a message stays that nobody set a time for: long enough to be
/// read (the 4.0 accessibility pass, WCAG's time limits), two seconds and a
/// little for each character of [message], from [kToastDuration] up to 15.
/// An error says what went wrong and often what to do: at least six seconds.
/// One with something to press (its action, Copy details) at least ten,
/// error or not: three seconds was not time to find the button.
Duration toastDurationFor({required bool isError, required bool tappable, String message = ''}) {
  final reading = Duration(milliseconds: (2000 + 60 * message.trim().length).clamp(3000, 15000));
  final least = tappable
      ? const Duration(seconds: 10)
      : isError
          ? const Duration(seconds: 6)
          : kToastDuration;
  return reading > least ? reading : least;
}

// ── Desktop: route to notification center ──────────────────────────

/// A desktop toast's title holds [max] characters (the notification center
/// cuts anything longer). A longer message keeps its first sentences that fit
/// as the title and the rest below it, so nothing is cut off; one with no
/// sentence end that early is split at a space.
(String, String?) splitToastMessage(String message, {int max = 120}) {
  final m = message.trim();
  if (m.length <= max) return (m, null);
  // A sentence ends at . ! ? before a space, or at the full stops of
  // Chinese, Japanese and Hindi, which need none.
  final ends = RegExp(r'[.!?](?=\s)|[。！？।]');
  var cut = -1;
  for (final e in ends.allMatches(m)) {
    if (e.end > max) break;
    cut = e.end;
  }
  if (cut > 0) return (m.substring(0, cut).trim(), m.substring(cut).trim());
  final space = m.lastIndexOf(' ', max - 1);
  final at = space > max ~/ 2 ? space : max - 1;
  return ('${m.substring(0, at).trimRight()}…', m.substring(at).trim());
}

SnackBarHandle _showDesktopNotification({
  required BuildContext context,
  required String message,
  required Duration duration,
  required bool isError,
  required bool isWarning,
  required bool isInfo,
  required bool isSuccess,
  required String? actionLabel,
  required VoidCallback? onAction,
  required String? details,
}) {
  // We use the closest ProviderScope, no-listen since we're firing
  // a one-shot push not subscribing.
  final container = ProviderScope.containerOf(context, listen: false);
  final notifier = container.read(notificationCenterProvider.notifier);

  // Severity precedence matches the doc on showTopSnackBar.
  final severity = isError
      ? NotificationSeverity.error
      : isWarning
          ? NotificationSeverity.warning
          : isSuccess
              ? NotificationSeverity.success
              : isInfo
                  ? NotificationSeverity.info
                  : NotificationSeverity.info;

  final completer = Completer<void>();
  void resolveOnce() {
    if (!completer.isCompleted) completer.complete();
  }

  // Wrap onAction so tapping the action button ALSO completes the
  // handle's `closed` future. The toast overlay already wraps onAction
  // in try/catch so an exception here won't crash the UI.
  VoidCallback? wrappedAction;
  if (actionLabel != null && onAction != null) {
    wrappedAction = () {
      try {
        onAction();
      } finally {
        resolveOnce();
      }
    };
  }

  // Errors stay sticky (Duration.zero on the notification center);
  // every other severity uses the caller's requested duration.
  final dismissAfter =
      severity == NotificationSeverity.error ? Duration.zero : duration;

  final (title, body) = splitToastMessage(message);
  notifier.show(AppNotification(
    id: const Uuid().v4(),
    title: title,
    body: body,
    severity: severity,
    actionLabel: actionLabel,
    onAction: wrappedAction,
    dismissAfter: dismissAfter,
    details: details,
    // A plain message: said again while it still stands, it is counted on
    // the one that stands (the same button pressed four times).
  ), countRepeats: true);

  // Auto-resolve the closed future when the toast would naturally
  // auto-dismiss.  We add a small slack so the notification center's
  // own dismissal timer fires first - keeps the "click Undo, then
  // expect the cleanup to run" sequence well-ordered.
  if (dismissAfter > Duration.zero) {
    Timer(dismissAfter + const Duration(milliseconds: 50), resolveOnce);
  }

  return SnackBarHandle(completer.future);
}

// ── Mobile: Overlay-anchored top toast ──────────────────────────────
//
// Previously a floating Material SnackBar positioned at the top via a
// `margin: bottom = screenHeight - 100` hack. That margin used the FULL
// window height while the SnackBar was laid out inside the keyboard-shrunk
// Scaffold, so whenever the keyboard was up the toast was pushed OFF the top
// of the screen - invisible in release, an assertion in debug (it fired
// constantly in the SFTP rename / new-folder / editor-save flows). This
// version inserts an OverlayEntry anchored from the TOP via SafeArea +
// Align, so the keyboard / viewInsets can't move it. Same public API.

/// The currently-visible mobile toast, so a new one replaces the old
/// (mirrors the previous `messenger.clearSnackBars()`).
_TopToastController? _activeMobileToast;

/// Bars at the top of a phone's screen holding controls a message must not
/// cover (the file editor's close and Done, 3.4):
/// while one is showing, a phone's message stands just below it instead of
/// at the top of the screen. The newest bar named that is showing wins.
final List<GlobalKey> _topToastBars = [];

/// Asks a phone's messages to stand below [bar] while it shows, until
/// [stopKeepingTopToastsBelow].
void keepTopToastsBelow(GlobalKey bar) => _topToastBars.add(bar);

void stopKeepingTopToastsBelow(GlobalKey bar) => _topToastBars.remove(bar);

/// How far down [overlay] the bottom of the newest bar named by
/// [keepTopToastsBelow] that is laid out stands; null where none is.
double? _belowTopBars(BuildContext overlay) {
  final ground = overlay.findRenderObject();
  if (ground is! RenderBox || !ground.attached) return null;
  for (final key in _topToastBars.reversed) {
    final box = key.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset(0, box.size.height), ancestor: ground).dy;
    }
  }
  return null;
}

SnackBarHandle _showMobileSnackBar({
  required BuildContext context,
  required String message,
  required Duration duration,
  required bool isError,
  required bool isWarning,
  required bool isInfo,
  required bool isSuccess,
  required String? actionLabel,
  required VoidCallback? onAction,
  required String? details,
  required double? width,
}) {
  // Severity → (icon, background). First match wins.
  final IconData? icon;
  final Color background;
  if (isError) {
    icon = LucideIcons.alertCircle;
    background = AppColors.v3Error;
  } else if (isWarning) {
    icon = LucideIcons.alertTriangle;
    background = AppColors.v3Warning;
  } else if (isInfo) {
    icon = LucideIcons.info;
    background = AppColors.v3Info;
  } else if (isSuccess) {
    icon = LucideIcons.checkCircle2;
    background = AppColors.v3Success;
  } else {
    icon = null;
    background = AppColors.v3Surface;
  }

  final completer = Completer<void>();
  void resolveOnce() {
    if (!completer.isCompleted) completer.complete();
  }

  // Replace any visible toast (graceful exit if it's still animating).
  _activeMobileToast?.dismiss();

  // A notice the app gives from outside any screen (a listener of the app, a
  // link) comes with the context of the app's navigator itself, which sits
  // above the navigator's overlay: no overlay was found above it, and the
  // notice was never drawn. The navigator's own overlay is where it goes.
  final overlay =
      Overlay.maybeOf(context, rootOverlay: true) ?? Navigator.maybeOf(context, rootNavigator: true)?.overlay;
  if (overlay == null || !context.mounted) {
    // Called too early / after teardown - resolve so awaiters don't hang.
    resolveOnce();
    return SnackBarHandle(completer.future);
  }

  final controller = _TopToastController();
  _activeMobileToast = controller;
  late final OverlayEntry entry;

  void removeEntry() {
    if (controller._removed) return;
    controller._removed = true;
    if (identical(_activeMobileToast, controller)) _activeMobileToast = null;
    entry.remove();
    resolveOnce();
  }

  controller._remove = removeEntry;

  entry = OverlayEntry(
    builder: (_) => _TopToastWidget(
      controller: controller,
      message: message,
      icon: icon,
      background: background,
      duration: duration,
      width: width,
      actionLabel: actionLabel,
      onAction: onAction,
      details: details,
      onFullyDismissed: removeEntry,
    ),
  );
  overlay.insert(entry);

  return SnackBarHandle(completer.future);
}

/// Bridges the imperative `dismiss()` (a newer toast replacing this one)
/// to the widget's exit animation.
class _TopToastController {
  VoidCallback? _remove; // hard-remove the overlay entry
  VoidCallback? _startExit; // ask the widget to animate out
  bool _removed = false;

  void dismiss() {
    if (_startExit != null) {
      _startExit!();
    } else {
      _remove?.call();
    }
  }
}

class _TopToastWidget extends StatefulWidget {
  const _TopToastWidget({
    required this.controller,
    required this.message,
    required this.icon,
    required this.background,
    required this.duration,
    required this.width,
    required this.actionLabel,
    required this.onAction,
    required this.details,
    required this.onFullyDismissed,
  });

  final _TopToastController controller;
  final String message;
  final IconData? icon;
  final Color background;
  final Duration duration;
  final double? width;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// The report "Copy details" copies; null where there is none.
  final String? details;
  final VoidCallback onFullyDismissed;

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  final _dismissKey = UniqueKey();
  Timer? _autoTimer;
  bool _exiting = false;

  /// Something on it to press: its action, or Copy details.
  bool get _tappable => widget.details != null || (widget.actionLabel != null && widget.onAction != null);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    widget.controller._startExit = _startExit;
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Less motion asked for: there at once, not slid in.
    if (zestReduceMotion(context)) {
      _anim.value = 1;
    } else {
      _anim.forward();
    }
    // Said to a screen reader as it shows (it was drawn, and nobody heard
    // it).
    zestAnnounce(context, widget.message);
    // With a screen reader on, one with something to press stays until it is
    // closed, as Material's snack bars do: finding its button by moving
    // through the screen takes longer than any time it could have.
    final stays = _tappable && MediaQuery.maybeAccessibleNavigationOf(context) == true;
    if (widget.duration > Duration.zero && !stays) {
      _autoTimer = Timer(widget.duration, _startExit);
    }
  }

  void _startExit() {
    if (_exiting || !mounted) return;
    _exiting = true;
    _autoTimer?.cancel();
    if (zestReduceMotion(context)) {
      widget.onFullyDismissed();
      return;
    }
    _anim.reverse().whenComplete(widget.onFullyDismissed);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Below a bar whose controls it must not cover, where one shows (the
    // bar already stands below the status bar); else at the top.
    final below = _belowTopBars(context.findAncestorStateOfType<OverlayState>()?.context ?? context);
    return Positioned(
      top: below ?? 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: below == null,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: _fade,
                child: Dismissible(
                  key: _dismissKey,
                  direction: DismissDirection.up,
                  onDismissed: (_) {
                    _autoTimer?.cancel();
                    widget.onFullyDismissed();
                  },
                  // Closed by a screen reader's dismiss action too, not only
                  // by a swipe up.
                  child: Semantics(
                    container: true,
                    onDismiss: _startExit,
                    child: _card(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card() {
    // Pick a foreground that actually contrasts with the toast background.
    // White-on-amber / white-on-green failed WCAG contrast; on those light
    // fills we need dark text, while error-red / charcoal need light text.
    final fg = _readableForeground(widget.background);
    Widget button(String label, VoidCallback onPressed, {Key? key}) => TextButton(
          key: key,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            // Use the same computed foreground - brand orange on amber/green
            // is itself low-contrast.
            foregroundColor: fg,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            // A phone's: 48 high to a finger, drawn 32.
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        );
    final details = widget.details;
    final copy = details == null
        ? null
        : button(
            AppLocalizations.of(context)?.desktopShellCopyDetails ?? 'Copy details',
            () {
              Clipboard.setData(ClipboardData(text: details));
              _startExit();
            },
            key: const ValueKey('toast-copy-details'),
          );
    final action = widget.actionLabel != null && widget.onAction != null
        ? button(widget.actionLabel!, () {
            widget.onAction!();
            _startExit();
          })
        : null;
    final message = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null) ...[
          ExcludeSemantics(child: Icon(widget.icon, color: fg, size: 18)),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            widget.message,
            style: TextStyle(fontSize: 13, color: fg),
          ),
        ),
        // One thing to tap stands beside the message; two go under it.
        if (action != null && copy == null) ...[const SizedBox(width: 8), action],
        if (copy != null && action == null) ...[const SizedBox(width: 8), copy],
      ],
    );
    final row = action != null && copy != null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              message,
              const SizedBox(height: 4),
              Wrap(alignment: WrapAlignment.end, spacing: 4, children: [copy, action]),
            ],
          )
        : message;

    final card = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: widget.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: row,
      ),
    );

    if (widget.width != null) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.width!),
        child: card,
      );
    }
    return SizedBox(width: double.infinity, child: card);
  }

  /// Choose dark or light foreground for [bg] by whichever gives the better
  /// WCAG contrast ratio. Dark candidate = v3Background, light = v3TextPrimary
  /// (both theme tokens, so this stays correct under custom themes).
  Color _readableForeground(Color bg) {
    final dark = AppColors.v3Background;
    final light = AppColors.v3TextPrimary;
    return _contrast(bg, dark) >= _contrast(bg, light) ? dark : light;
  }

  double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}
