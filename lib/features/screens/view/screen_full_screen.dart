// A remote screen in full screen on a computer (4.0): the picture alone
// on the whole monitor, and the way out of it. A slim bar slides down when
// the pointer touches the top edge, as other remote desktop programs have
// it, and goes again when the pointer leaves it; a line says for a few
// seconds, on entering, how to get out. A small handle on the edge the
// session panel slides in from opens that panel, drawn beside the picture
// where the picture leaves room. Shared by a tab's screen (the main window in
// full screen, the app's own bars not drawn) and a screen in a window of its
// own. Where the remote has several displays, a button for each beside the
// picture on the other edge (or in the bar at the top edge where the picture
// leaves no room there), and the keys that show them (Alt and a digit unless
// changed) work as in its tab.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The session whose screen is in full screen over the main window now, or
/// null. The app's own bars, side bar and status bar are under it then, and
/// step out of what a screen reader is told and of the keyboard's way
/// through the window (the desktop shell watches this).
final screenFullScreenSessionProvider = StateProvider<String?>((ref) => null);

/// What the bar at the top edge offers. A null action is not offered.
class ScreenFullScreenBarActions {
  const ScreenFullScreenBarActions({
    required this.onExit,
    required this.exitLabel,
    required this.onMenu,
    required this.menuLabel,
    this.onDisconnect,
    this.disconnectLabel,
    this.onBack,
    this.backLabel,
  });

  final VoidCallback onExit;
  final String exitLabel;
  final VoidCallback onMenu;
  final String menuLabel;

  /// Ends the session (a tab's screen; asked about before it is done).
  final VoidCallback? onDisconnect;
  final String? disconnectLabel;

  /// Brings the screen back to its tab (a window of its own).
  final VoidCallback? onBack;
  final String? backLabel;
}

/// [child] (the picture, with whatever covers it) on the whole of its
/// space, with the bar at its top edge and the line about the way out.
class ScreenFullScreenFrame extends StatefulWidget {
  const ScreenFullScreenFrame({
    super.key,
    required this.child,
    required this.actions,
    required this.hint,
    this.title,
    this.picture,
    this.hintStays = const Duration(seconds: 5),
    this.barLeaves = const Duration(milliseconds: 700),
    this.displayKeyLabels = const [],
  });

  /// The keys that show displays 1 to 4, as their labels (null: none set),
  /// said in the tooltips of the display buttons.
  final List<String?> displayKeyLabels;

  /// The display buttons: a column in the band beside the picture on the
  /// start edge where that band is at least [displaysBandMin] wide (centred
  /// in it, at most [displaysColumnWidth] wide), else a row in the bar that
  /// comes down from the top edge, never over the picture.
  static const displaysBandMin = 48.0;
  static const displaysColumnWidth = 44.0;

  final Widget child;
  final ScreenFullScreenBarActions actions;

  /// The picture's controller, for the handle that opens the session panel
  /// ([ScreenFullScreenBarActions.onMenu]). The picture's view shares this
  /// frame's height and the edge the panel slides in from (the end edge),
  /// so the room beside the picture there is read from where the view puts
  /// it. Null: no handle.
  final ScreenController? picture;

  /// The handle: [handleWidth] wide where the room beside the picture has
  /// that much, as wide as the room where it has less, and never less than
  /// [handleSlim], all it may cover of a picture that reaches the edge;
  /// [handleHeight] tall, centred on the edge.
  static const handleWidth = 16.0;
  static const handleSlim = 4.0;
  static const handleHeight = 56.0;

  /// The handle's width where [room] logical pixels at the edge are not
  /// picture.
  static double handleWidthBeside(double room) => room >= handleWidth ? handleWidth : math.max(room, handleSlim);

  /// The host's name, where it is known here (a tab's; a window of its own
  /// is never told it).
  final String? title;

  /// Said for [hintStays] on entering: the keys that lead out. Empty: nothing
  /// is said here (a window of its own has a line of its own).
  final String hint;
  final Duration hintStays;

  /// How long the bar stays once the pointer has left it.
  final Duration barLeaves;

  /// How tall the strip at the top edge is that brings the bar down.
  static const edge = 3.0;

  @override
  State<ScreenFullScreenFrame> createState() => _ScreenFullScreenFrameState();
}

class _ScreenFullScreenFrameState extends State<ScreenFullScreenFrame> {
  bool _bar = false;
  bool _hint = true;
  Timer? _hintTimer;
  Timer? _leave;

  @override
  void initState() {
    super.initState();
    _hintTimer = Timer(widget.hintStays, () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _leave?.cancel();
    super.dispose();
  }

  void _show() {
    _leave?.cancel();
    if (!_bar) setState(() => _bar = true);
  }

  void _hideSoon() {
    _leave?.cancel();
    _leave = Timer(widget.barLeaves, () {
      if (mounted) setState(() => _bar = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.actions;
    // The keyboard's way through: the handle first, then the bar's buttons,
    // then the picture, which keeps Tab for the remote once it has the focus.
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Stack(
      fit: StackFit.expand,
      children: [
        FocusTraversalOrder(order: const NumericFocusOrder(2), child: widget.child),
        // The line about the way out, under where the bar comes down.
        if (_hint && !_bar && widget.hint.isNotEmpty)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ZestColors.surfacePanel.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ZestColors.borderSubtle),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Text(
                      widget.hint,
                      key: const ValueKey('screen-full-screen-hint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, color: ZestColors.textPrimary),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // The handle on the edge the session panel comes from. Placed as the
        // frame is laid out, after the picture: its width follows the room
        // the view leaves beside the picture at that size, scaling, zoom and
        // pan, and is placed again whenever the picture's controller changes.
        if (widget.picture case final picture?)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _HandleLayout(picture, Directionality.of(context)),
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(0),
                child: _MenuHandle(label: AppLocalizations.of(context)!.screenSessionMenu, onTap: a.onMenu),
              ),
            ),
          ),
        // The remote's displays, where it has several: buttons in the room
        // beside the picture on the start edge; where the picture leaves no
        // room there, in the bar at the top edge instead (never over the
        // picture, whose clicks are the remote's).
        if (widget.picture case final picture?)
          Positioned.fill(
            child: ListenableBuilder(
              listenable: picture,
              builder: (context, _) => _DisplaysLayout.inBandOf(picture, Directionality.of(context))
                  ? CustomSingleChildLayout(
                      delegate: _DisplaysLayout(picture, Directionality.of(context)),
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(0.5),
                        child: _DisplayButtons(picture: picture, keyLabels: widget.displayKeyLabels),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        // The strip at the top edge: the pointer on it brings the bar down.
        // Nothing is taken from the picture but its top few pixels' hover.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: ScreenFullScreenFrame.edge,
          child: MouseRegion(
            key: const ValueKey('screen-full-screen-edge'),
            opaque: false,
            onEnter: (_) => _show(),
          ),
        ),
        // The bar: in the tree only while it is shown, so nothing of it is
        // found, read out or pressed while the picture has the whole screen.
        if (_bar)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: -1, end: 0),
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              builder: (context, at, child) => FractionalTranslation(translation: Offset(0, at), child: child),
              child: Center(
                child: MouseRegion(
                  onEnter: (_) => _show(),
                  onExit: (_) => _hideSoon(),
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: _Bar(
                      title: widget.title,
                      actions: a,
                      // The displays, where there is no room beside the picture.
                      displays: switch (widget.picture) {
                        final picture? when !_DisplaysLayout.inBandOf(picture, Directionality.of(context)) =>
                          _DisplayButtons(picture: picture, keyLabels: widget.displayKeyLabels, row: true),
                        _ => null,
                      },
                    ),
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

class _Bar extends StatelessWidget {
  const _Bar({required this.title, required this.actions, this.displays});

  final String? title;

  /// The remote's display buttons, after the title (none: not shown here).
  final Widget? displays;
  final ScreenFullScreenBarActions actions;

  @override
  Widget build(BuildContext context) {
    final a = actions;
    Widget button(String key, IconData glyph, String label, VoidCallback onTap, {bool danger = false}) => TextButton.icon(
          key: ValueKey(key),
          onPressed: onTap,
          icon: Icon(glyph, size: 15),
          label: Text(label),
          style: TextButton.styleFrom(
            foregroundColor: danger ? AppColors.error : ZestColors.textPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5),
          ),
        );
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('screen-full-screen-bar'),
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: ZestColors.surfacePanel,
          border: Border.all(color: ZestColors.borderSubtle),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null && title!.isNotEmpty) ...[
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(
                  title!,
                  key: const ValueKey('screen-full-screen-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (displays != null) ...[displays!, const SizedBox(width: 8)],
            button('screen-full-screen-exit', LucideIcons.minimize2, a.exitLabel, a.onExit),
            button('screen-full-screen-menu', LucideIcons.menu, a.menuLabel, a.onMenu),
            if (a.onBack != null && a.backLabel != null)
              button('screen-full-screen-back', LucideIcons.cornerUpLeft, a.backLabel!, a.onBack!),
            if (a.onDisconnect != null && a.disconnectLabel != null)
              button('screen-full-screen-disconnect', LucideIcons.power, a.disconnectLabel!, a.onDisconnect!, danger: true),
          ],
        ),
      ),
    );
  }
}

/// Where the handle goes: on the end edge, centred on it, as wide as the
/// room the picture leaves there allows ([ScreenFullScreenFrame.handleWidthBeside]).
class _HandleLayout extends SingleChildLayoutDelegate {
  _HandleLayout(this.picture, this.direction) : super(relayout: picture);

  final ScreenController picture;
  final TextDirection direction;

  bool get _rtl => direction == TextDirection.rtl;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final v = picture.viewport;
    final r = v.pictureRect;
    // What is not picture between the picture and the end edge: none where
    // the picture reaches the edge, or goes past it zoomed in.
    final room = _rtl ? r.left : v.viewSize.width - r.right;
    return BoxConstraints.tightFor(
      width: math.min(ScreenFullScreenFrame.handleWidthBeside(room), constraints.maxWidth),
      height: math.min(ScreenFullScreenFrame.handleHeight, constraints.maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      Offset(_rtl ? 0 : size.width - childSize.width, ((size.height - childSize.height) / 2).floorToDouble());

  // The picture's place is read again at every layout.
  @override
  bool shouldRelayout(_HandleLayout oldDelegate) => true;
}

/// Where the display buttons go ([ScreenFullScreenFrame.displaysBandMin]).
class _DisplaysLayout extends SingleChildLayoutDelegate {
  _DisplaysLayout(this.picture, this.direction) : super(relayout: Listenable.merge([picture, picture.displays]));

  final ScreenController picture;
  final TextDirection direction;

  bool get _rtl => direction == TextDirection.rtl;

  /// The room between the start edge and the picture.
  double get _room {
    final v = picture.viewport;
    final r = v.pictureRect;
    return math.max(0, _rtl ? v.viewSize.width - r.right : r.left);
  }

  /// Whether the room beside [picture] on the start edge holds the buttons.
  static bool inBandOf(ScreenController picture, TextDirection direction) =>
      _DisplaysLayout(picture, direction)._room >= ScreenFullScreenFrame.displaysBandMin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
        maxWidth: math.max(0, math.min(ScreenFullScreenFrame.displaysColumnWidth, _room - 8)),
        maxHeight: math.max(0, constraints.maxHeight - 16),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (_room - childSize.width) / 2;
    return Offset((_rtl ? size.width - x - childSize.width : x).floorToDouble(),
        ((size.height - childSize.height) / 2).floorToDouble());
  }

  @override
  bool shouldRelayout(_DisplaysLayout oldDelegate) => true;
}

/// One button for each display and one for all of them, the one shown
/// filled; nothing where the remote has one display. Down a column beside
/// the picture, or along a row in the bar at the top edge ([row]).
class _DisplayButtons extends StatelessWidget {
  const _DisplayButtons({required this.picture, required this.keyLabels, this.row = false});

  final ScreenController picture;
  final List<String?> keyLabels;

  /// Along a row (in the bar), not down a column.
  final bool row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder(
      valueListenable: picture.displays,
      builder: (context, d, _) {
        if (!d.several) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, c) {
          final column = !row && c.maxHeight > 60;
          final buttons = [
            for (var i = 0; i < d.list.length; i++)
              _DisplayButton(
                key: ValueKey('screen-full-screen-display-$i'),
                text: '${i + 1}',
                label: l10n.screenDisplayName(i + 1),
                keyLabel: i < keyLabels.length ? keyLabels[i] : null,
                on: d.shown == i,
                onTap: () => picture.showDisplay(i),
              ),
            _DisplayButton(
              key: const ValueKey('screen-full-screen-display-all'),
              text: l10n.screenDisplayAllShort,
              label: l10n.screenDisplayAll,
              on: d.shown == null,
              onTap: () => picture.showDisplay(null),
            ),
          ];
          return Semantics(
            container: true,
            explicitChildNodes: true,
            child: column
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final b in buttons) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: b),
                  ])
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final b in buttons) Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: b),
                  ]),
          );
        });
      },
    );
  }
}

class _DisplayButton extends StatefulWidget {
  const _DisplayButton({
    super.key,
    required this.text,
    required this.label,
    required this.on,
    required this.onTap,
    this.keyLabel,
  });

  final String text;
  final String label;
  final String? keyLabel;
  final bool on;
  final VoidCallback onTap;

  @override
  State<_DisplayButton> createState() => _DisplayButtonState();
}

class _DisplayButtonState extends State<_DisplayButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hovered || _focused || widget.on;
    final tip = widget.keyLabel == null ? widget.label : '${widget.label} (${widget.keyLabel})';
    return Semantics(
      button: true,
      selected: widget.on,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Tooltip(
        message: tip,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (on) => setState(() => _hovered = on),
            onFocusChange: (on) => setState(() => _focused = on),
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(7),
            child: AnimatedOpacity(
              opacity: lit ? 1 : 0.5,
              duration: const Duration(milliseconds: 120),
              child: Container(
                constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.on ? ZestColors.accentPrimary : ZestColors.surfacePanel,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                      color: widget.on
                          ? ZestColors.accentPrimary
                          : (_hovered || _focused ? ZestColors.borderDefault : ZestColors.borderSubtle)),
                ),
                child: Text(
                  widget.text,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: widget.on ? const Color(0xFF161004) : ZestColors.textPrimary,
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

/// The handle itself: faint until the pointer is on it or it has the
/// keyboard's focus; a button named [label] to a screen reader.
class _MenuHandle extends StatefulWidget {
  const _MenuHandle({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_MenuHandle> createState() => _MenuHandleState();
}

class _MenuHandleState extends State<_MenuHandle> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final lit = _hovered || _focused;
    // Rounded on the side toward the picture, square on the monitor's edge.
    final radius = const BorderRadiusDirectional.horizontal(start: Radius.circular(6)).resolve(Directionality.of(context));
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('screen-full-screen-handle'),
            onTap: widget.onTap,
            onHover: (on) => setState(() => _hovered = on),
            onFocusChange: (on) => setState(() => _focused = on),
            mouseCursor: SystemMouseCursors.click,
            borderRadius: radius,
            child: AnimatedOpacity(
              opacity: lit ? 1 : 0.35,
              duration: const Duration(milliseconds: 120),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ZestColors.surfacePanel,
                  borderRadius: radius,
                  border: Border.all(color: lit ? ZestColors.borderDefault : ZestColors.borderSubtle),
                ),
                // The arrow where the handle is wide enough to hold it; a
                // slim handle on a picture that reaches the edge is a line.
                child: LayoutBuilder(
                  builder: (context, size) => size.maxWidth < 12
                      ? const SizedBox.expand()
                      : Center(
                          child: Icon(rtl ? LucideIcons.chevronRight : LucideIcons.chevronLeft,
                              size: 14, color: ZestColors.textPrimary),
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
