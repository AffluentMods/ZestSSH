import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/ui/widgets/zest_in_place.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

export 'package:zestssh/ui/widgets/zest_in_place.dart' show zestDialogPop;

/// The three desktop modal size classes (UX audit §1).
///
/// A dialog is assigned exactly one class by intent, not by pixel guesswork:
///   * [compact]  - a single decision or a single input (confirm, password,
///     rename). Not resizable.
///   * [standard] - a form with several related fields (new network, add port
///     forward). Not resizable; height follows content, capped with scroll.
///   * [large]    - a form complex enough for multiple columns/sections (host
///     config, sync storage). Widest tier.
enum ZestModalSize { compact, standard, large }

/// Resolved geometry for a [ZestModalSize].
class ZestModalSpec {
  final double minWidth;
  final double maxWidth;

  /// Fraction of the window height the modal may occupy before its body
  /// scrolls. Keeps a modal from ever being taller than its content needs.
  final double maxHeightFraction;

  const ZestModalSpec({
    required this.minWidth,
    required this.maxWidth,
    required this.maxHeightFraction,
  });
}

extension ZestModalSizeX on ZestModalSize {
  ZestModalSpec get spec {
    switch (this) {
      case ZestModalSize.compact:
        return const ZestModalSpec(
            minWidth: 380, maxWidth: 440, maxHeightFraction: 0.9);
      case ZestModalSize.standard:
        return const ZestModalSpec(
            minWidth: 560, maxWidth: 680, maxHeightFraction: 0.85);
      case ZestModalSize.large:
        return const ZestModalSpec(
            minWidth: 820, maxWidth: 960, maxHeightFraction: 0.9);
    }
  }
}

/// Show a size-classed modal that satisfies the desktop modal contract:
///
///  * A dim scrim sits behind it (via [showDialog]'s barrier); clicking it
///    dismisses when there is no unsaved input.
///  * **Escape** closes, guarded by [onDismissAttempt] when there IS unsaved
///    input (return false to keep it open). **Enter** invokes [onSubmit] when
///    focus is not in a field that consumes the key (multiline / submitting).
///  * Focus enters on open, is trapped, and returns to the opener on close
///    (Flutter's [DialogRoute] handles this).
///
/// [child] is a full dialog widget - typically a [ZestDialogShell] built with
/// the same [size], which sizes itself from the class. The host adds only the
/// keyboard/scrim behavior the shell doesn't provide.
///
/// [useRootNavigator]: which navigator it opens on; by default the app's own
/// for a dialog (as showDialog's) and the nearest for a phone's sheet (as
/// showModalBottomSheet's). Give it where the caller closes it on a named
/// navigator, so the dialog and the sheet are on the one it closes.
Future<T?> showZestModal<T>({
  required BuildContext context,
  required ZestModalSize size,
  required Widget child,
  bool barrierDismissible = true,
  Future<bool> Function()? onDismissAttempt,
  VoidCallback? onSubmit,
  bool? useRootNavigator,
}) {
  // A phone: a bottom sheet (3.0 UI).
  if (zestUsesSheets(context)) {
    return showZestSheet<T>(
      context: context,
      dismissible: onDismissAttempt == null && barrierDismissible,
      useRootNavigator: useRootNavigator ?? false,
      child: _ZestModalBehavior(
        onDismissAttempt: onDismissAttempt,
        onSubmit: onSubmit,
        child: child,
      ),
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator ?? true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    // When there's an unsaved-changes guard we take over dismissal (Escape +
    // scrim) so we can confirm first; otherwise the barrier dismisses normally.
    barrierDismissible: onDismissAttempt == null && barrierDismissible,
    // A follow-up shows in this dialog's place ([showZestInPlace]).
    builder: (context) => ZestInPlaceHost(
      child: _ZestModalBehavior(
        onDismissAttempt: onDismissAttempt,
        onSubmit: onSubmit,
        child: child,
      ),
    ),
  );
}

/// A follow-up of the dialog [context] is in (rule 4 of the dialog rules,
/// 3.4: no dialog over a dialog): shown in that dialog's place, which comes
/// back as it was once this is answered ([ZestInPlaceHost]); where [context]
/// is in no dialog, or not in the one in front, a dialog of its own
/// ([showZestModal], [size]). What [builder] builds closes with
/// [zestDialogPop], never Navigator.pop, which would close the dialog under it.
/// [onSubmit] and [onDismissAttempt] are Enter and Escape's, as showZestModal's.
Future<T?> showZestInPlace<T>({
  required BuildContext context,
  required ZestModalSize size,
  required WidgetBuilder builder,
  VoidCallback? onSubmit,
  Future<bool> Function()? onDismissAttempt,
  bool barrierDismissible = true,
  bool? useRootNavigator,
}) {
  final host = ZestInPlaceHost.maybeOf(context);
  if (host != null) {
    return host.show<T>(builder, onSubmit: onSubmit, onDismissAttempt: onDismissAttempt);
  }
  return showZestModal<T>(
    context: context,
    size: size,
    onSubmit: onSubmit,
    onDismissAttempt: onDismissAttempt,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    child: Builder(builder: builder),
  );
}

class _ZestModalBehavior extends StatefulWidget {
  const _ZestModalBehavior({
    required this.child,
    this.onDismissAttempt,
    this.onSubmit,
  });

  final Widget child;
  final Future<bool> Function()? onDismissAttempt;
  final VoidCallback? onSubmit;

  @override
  State<_ZestModalBehavior> createState() => _ZestModalBehaviorState();
}

class _ZestModalBehaviorState extends State<_ZestModalBehavior> {
  bool _dismissing = false;

  Future<void> _handleDismiss() async {
    if (widget.onDismissAttempt != null) {
      if (_dismissing) return;
      _dismissing = true;
      final allow = await widget.onDismissAttempt!();
      _dismissing = false;
      if (!allow) return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): const _DismissModalIntent(),
        if (widget.onSubmit != null) ...{
          LogicalKeySet(LogicalKeyboardKey.enter): const _SubmitModalIntent(),
          LogicalKeySet(LogicalKeyboardKey.numpadEnter):
              const _SubmitModalIntent(),
        },
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissModalIntent: CallbackAction<_DismissModalIntent>(
            onInvoke: (_) {
              _handleDismiss();
              return null;
            },
          ),
          _SubmitModalIntent: _SubmitModalAction(widget.onSubmit),
        },
        child: widget.child,
      ),
    );
  }
}

class _DismissModalIntent extends Intent {
  const _DismissModalIntent();
}

class _SubmitModalIntent extends Intent {
  const _SubmitModalIntent();
}

/// Enter submits the modal, except while the keyboard is in a text field of
/// several lines: there the key is left to the field, which makes it a new
/// line (it submitted the dialog half-typed).
class _SubmitModalAction extends Action<_SubmitModalIntent> {
  _SubmitModalAction(this.onSubmit);

  final VoidCallback? onSubmit;

  @override
  bool isEnabled(_SubmitModalIntent intent) => onSubmit != null && !zestFocusInMultilineText();

  @override
  Object? invoke(_SubmitModalIntent intent) {
    onSubmit?.call();
    return null;
  }
}
