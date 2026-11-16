import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;

/// Rule 4 of the app's dialog rules (3.4): no
/// dialog over a dialog. A follow-up (a question it asks, a host to choose, a
/// custom colour) changes the dialog in place, and the dialog comes back as it
/// was, with what was typed in it, when the follow-up is answered.
///
/// Every dialog of the app's own (showZestModal, a phone's sheet, a
/// ZestConfirmDialog) stands in one of these. While a follow-up shows, the
/// dialog under it is kept but not drawn, cannot take the keyboard and is not
/// read out; Escape, back and a tap outside answer the follow-up (null), not
/// the dialog. The dialog's own Enter is not pressed by an Enter meant for the
/// follow-up.
class ZestInPlaceHost extends StatefulWidget {
  const ZestInPlaceHost({super.key, required this.child});

  /// The dialog.
  final Widget child;

  /// The dialog [context] is in, where a follow-up can show in its place now:
  /// null where [context] is in no dialog of the app's, or where that dialog is
  /// not the one in front (it is closing, or something opened over it).
  static ZestInPlaceHostState? maybeOf(BuildContext context) {
    final host = context.findAncestorStateOfType<ZestInPlaceHostState>();
    return host != null && host._available ? host : null;
  }

  @override
  State<ZestInPlaceHost> createState() => ZestInPlaceHostState();
}

/// Closes the dialog [context] is in with [result]: a follow-up shown in place
/// goes back to the dialog it changed; any other dialog's route is popped (as
/// Navigator.pop). What a follow-up shows closes with this, never with
/// Navigator.pop, which would close the dialog under it.
void zestDialogPop<T extends Object?>(BuildContext context, [T? result]) {
  final scope = context.getInheritedWidgetOfExactType<_FollowUpScope>();
  if (scope != null) {
    scope.close(result);
    return;
  }
  Navigator.of(context).pop<T>(result);
}

/// Whether the keyboard is in a text field of several lines, where Enter is a
/// new line and submits nothing.
bool zestFocusInMultilineText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final field = context.widget is EditableText
      ? context.widget as EditableText
      : context.findAncestorWidgetOfExactType<EditableText>();
  return field != null && field.maxLines != 1;
}

class _FollowUp {
  _FollowUp({
    required this.builder,
    required this.onSubmit,
    required this.onDismissAttempt,
    required this.focusBefore,
    required this.complete,
  });

  final WidgetBuilder builder;
  final VoidCallback? onSubmit;
  final Future<bool> Function()? onDismissAttempt;

  /// What had the keyboard in the dialog, given it back when this closes.
  final FocusNode? focusBefore;
  final void Function(Object? value) complete;
  final FocusScopeNode scope = FocusScopeNode(debugLabel: 'zest-in-place');
  bool dismissing = false;
}

/// [ZestInPlaceHost]'s state: what shows follow-ups in its dialog's place.
class ZestInPlaceHostState extends State<ZestInPlaceHost> {
  final _followUps = <_FollowUp>[];
  late final _popEntry = _BlockPop(_dismissTop);
  ModalRoute<Object?>? _route;
  bool _registered = false;

  bool get _available => mounted && (_route?.isCurrent ?? false);

  /// Whether a follow-up shows now.
  bool get showsFollowUp => _followUps.isNotEmpty;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_registered) {
        _route?.unregisterPopEntry(_popEntry);
        _registered = false;
      }
      _route = route;
      _syncPopEntry();
    }
  }

  /// Shows what [builder] builds in the dialog's place, and resolves with what
  /// it closes with ([zestDialogPop]), or null where it was closed without an
  /// answer (Escape, back, a tap outside, the dialog closing under it).
  /// [onSubmit]: what Enter does in it (nothing by default; a button or a
  /// field that takes Enter itself keeps it). [onDismissAttempt]: asked before
  /// Escape, back or a tap outside closes it; false leaves it open.
  Future<T?> show<T>(
    WidgetBuilder builder, {
    VoidCallback? onSubmit,
    Future<bool> Function()? onDismissAttempt,
  }) {
    final done = Completer<T?>();
    final followUp = _FollowUp(
      builder: builder,
      onSubmit: onSubmit,
      onDismissAttempt: onDismissAttempt,
      focusBefore: FocusManager.instance.primaryFocus,
      complete: (value) {
        if (!done.isCompleted) done.complete(value is T ? value : null);
      },
    );
    setState(() => _followUps.add(followUp));
    _syncPopEntry();
    return done.future;
  }

  void _close(_FollowUp followUp, Object? value) {
    if (!_followUps.contains(followUp)) return;
    final wasOnTop = identical(followUp, _followUps.last);
    setState(() => _followUps.remove(followUp));
    // At once, not at the next frame: a dialog closed just after its
    // follow-up was answered (a Discard that closes it) must not be held.
    _syncPopEntry();
    followUp.complete(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      followUp.scope.dispose();
      final back = followUp.focusBefore;
      if (wasOnTop && mounted && back != null && back.context != null && back.canRequestFocus) {
        back.requestFocus();
      }
    });
  }

  Future<void> _dismissTop() async {
    if (_followUps.isEmpty) return;
    final top = _followUps.last;
    if (top.onDismissAttempt != null) {
      if (top.dismissing) return;
      top.dismissing = true;
      final close = await top.onDismissAttempt!();
      top.dismissing = false;
      if (!close || !mounted) return;
    }
    _close(top, null);
  }

  void _syncPopEntry() {
    final want = _followUps.isNotEmpty && _route != null;
    if (want == _registered) return;
    if (want) {
      _route!.registerPopEntry(_popEntry);
    } else {
      _route!.unregisterPopEntry(_popEntry);
    }
    _registered = want;
  }

  @override
  void dispose() {
    if (_registered) _route?.unregisterPopEntry(_popEntry);
    _registered = false;
    // The dialog closed with its follow-ups open: they are answered null.
    for (final followUp in _followUps) {
      followUp.complete(null);
      followUp.scope.dispose();
    }
    _followUps.clear();
    _popEntry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _followUps.isNotEmpty;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        _Kept(away: shown, child: widget.child),
        for (final (i, followUp) in _followUps.indexed)
          KeyedSubtree(
            key: ObjectKey(followUp),
            child: _Kept(
              away: i != _followUps.length - 1,
              child: _FollowUpScope(
                close: (value) => _close(followUp, value),
                child: Shortcuts(
                  shortcuts: <ShortcutActivator, Intent>{
                    const SingleActivator(LogicalKeyboardKey.escape): const _DismissFollowUpIntent(),
                    // Enter never reaches the dialog under it: the follow-up's
                    // own, or nothing (a field still gets it for itself).
                    for (final enter in const [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter])
                      SingleActivator(enter): followUp.onSubmit == null
                          ? const DoNothingAndStopPropagationIntent()
                          : const _SubmitFollowUpIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _DismissFollowUpIntent: CallbackAction<_DismissFollowUpIntent>(onInvoke: (_) {
                        _dismissTop();
                        return null;
                      }),
                      _SubmitFollowUpIntent: _SubmitFollowUpAction(followUp.onSubmit),
                    },
                    child: FocusScope(
                      node: followUp.scope,
                      child: Focus(
                        autofocus: true,
                        child: Builder(builder: followUp.builder),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A dialog, or a follow-up under another, kept as it is while another shows
/// in its place: not drawn, not touched, not read out, no keyboard, its
/// animations held.
class _Kept extends StatelessWidget {
  const _Kept({required this.away, required this.child});

  final bool away;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: away,
        child: TickerMode(
          enabled: !away,
          child: ExcludeFocus(excluding: away, child: _KeptScope(away: away, child: child)),
        ),
      );
}

/// Whether what is under it is kept away now ([_Kept]).
class _KeptScope extends InheritedWidget {
  const _KeptScope({required this.away, required super.child});

  final bool away;

  @override
  bool updateShouldNotify(_KeptScope oldWidget) => away != oldWidget.away;
}

/// Says a dialog's [title] to a screen reader where the dialog changes in
/// place (4.0 accessibility pass): as a follow-up shows in a dialog's place,
/// and as a dialog (or a follow-up) comes back once the one shown in its
/// place is answered. A dialog that opens as a route of its own is named by
/// its route (its title's namesRoute); one shown in place opened no route,
/// and a reader heard nothing of the new title, only the field or button
/// the keyboard went to. Every [ZestDialogShell] stands in one.
class ZestInPlaceTitle extends StatefulWidget {
  const ZestInPlaceTitle({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  State<ZestInPlaceTitle> createState() => _ZestInPlaceTitleState();
}

class _ZestInPlaceTitleState extends State<ZestInPlaceTitle> {
  bool? _away;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final away = context.dependOnInheritedWidgetOfExactType<_KeptScope>()?.away;
    if (away == null) return;
    final first = _away == null;
    final cameBack = _away == true && !away;
    _away = away;
    final shownInPlace = first && !away && context.getInheritedWidgetOfExactType<_FollowUpScope>() != null;
    if (shownInPlace || cameBack) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _away == false) zestAnnounce(context, widget.title);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FollowUpScope extends InheritedWidget {
  const _FollowUpScope({required this.close, required super.child});

  final void Function(Object? value) close;

  @override
  bool updateShouldNotify(_FollowUpScope oldWidget) => false;
}

/// Holds the dialog's route while a follow-up shows: back and a tap outside
/// answer the follow-up instead of closing the dialog.
class _BlockPop extends PopEntry<Object?> {
  _BlockPop(this.onBlocked);

  final Future<void> Function() onBlocked;
  final _canPop = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    // After the route has told every entry: answering the follow-up takes
    // this entry out of the route's set, which is being gone through now.
    if (!didPop) scheduleMicrotask(() => unawaited(onBlocked()));
  }

  void dispose() => _canPop.dispose();
}

class _DismissFollowUpIntent extends Intent {
  const _DismissFollowUpIntent();
}

class _SubmitFollowUpIntent extends Intent {
  const _SubmitFollowUpIntent();
}

/// Enter does the follow-up's [onSubmit], except in a text field of several
/// lines, which takes it for a new line.
class _SubmitFollowUpAction extends Action<_SubmitFollowUpIntent> {
  _SubmitFollowUpAction(this.onSubmit);

  final VoidCallback? onSubmit;

  @override
  bool isEnabled(_SubmitFollowUpIntent intent) => onSubmit != null && !zestFocusInMultilineText();

  @override
  Object? invoke(_SubmitFollowUpIntent intent) {
    onSubmit?.call();
    return null;
  }
}
