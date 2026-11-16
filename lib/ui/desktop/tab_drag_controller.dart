import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Minimum pointer movement (in screen pixels) before any drag mode activates.
const double kDragActivationDistance = 12.0;

/// Pixels below the tab bar bottom edge before detach triggers.
/// Set high (80px) to prevent accidental detach - user must deliberately
/// drag well below the tab bar.
const double kVerticalDetachThreshold = 80.0;

/// Pixels above the tab bar top edge before detach triggers.
const double kVerticalDetachThresholdUp = 60.0;

/// Minimum time the pointer must be held before any drag mode activates.
/// Prevents accidental detach on fast clicks.
const Duration kMinDragDuration = Duration(milliseconds: 200);

/// The states of the tab-drag state machine.
enum TabDragState { idle, pending, reordering, detaching }

/// Signature for when a tab is torn off the bar.
typedef OnTabDetach = void Function(int tabIndex, Offset screenPosition);

/// A state machine that distinguishes three gestures on a tab:
///
/// 1. **Click** - no significant movement → select tab (handled externally).
/// 2. **Horizontal drag** - reorder tabs (handled by ReorderableListView).
/// 3. **Vertical drag past threshold** - detach into a new OS window.
///
/// Feed raw [PointerEvent]s from [Listener] widgets. The controller uses
/// SCREEN coordinates (via [localToGlobal]) for all threshold checks to
/// avoid coordinate-space mismatches between nested widgets.
class TabDragController {
  TabDragState _state = TabDragState.idle;
  int? _draggedTabIndex;

  /// Screen-space position where the drag started.
  Offset? _dragStartScreen;
  DateTime? _dragStartTime;
  GlobalKey? _tabBarKey;

  /// Called when the cursor moves far enough below/above the tab bar.
  final OnTabDetach? onDetach;

  /// Called when any drag gesture ends.
  final VoidCallback? onDragEnd;

  TabDragController({this.onDetach, this.onDragEnd});

  TabDragState get state => _state;
  int? get draggedTabIndex => _draggedTabIndex;

  /// Store a reference to the tab bar's [GlobalKey] so the controller can
  /// compute the bar's screen-space rectangle.
  void setTabBarKey(GlobalKey key) => _tabBarKey = key;

  /// Compute the tab bar's screen-space rectangle.
  Rect? _getTabBarScreenRect() {
    final renderBox =
        _tabBarKey?.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return null;
    final topLeft = renderBox.localToGlobal(Offset.zero);
    return topLeft & renderBox.size;
  }

  /// Call from [Listener.onPointerDown] on each tab widget.
  /// [context] is the tab widget's BuildContext for coordinate conversion.
  void onPointerDown(int tabIndex, PointerDownEvent event, BuildContext context) {
    if (event.buttons != kPrimaryButton) return;

    // Convert to screen coordinates immediately so all comparisons
    // use the same coordinate space.
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;

    _state = TabDragState.pending;
    _draggedTabIndex = tabIndex;
    _dragStartScreen = renderBox.localToGlobal(event.localPosition);
    _dragStartTime = DateTime.now();
  }

  /// Call from [Listener.onPointerMove] on the tab bar container.
  /// [context] is the container's BuildContext for coordinate conversion.
  void onPointerMove(PointerMoveEvent event, BuildContext context) {
    if (_draggedTabIndex == null || _dragStartScreen == null) return;

    // Convert current position to screen coordinates.
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final screenPos = renderBox.localToGlobal(event.localPosition);

    // Screen-space delta from the drag start point.
    final delta = screenPos - _dragStartScreen!;

    switch (_state) {
      case TabDragState.pending:
        // Require minimum movement distance.
        if (delta.distance < kDragActivationDistance) return;

        // Require minimum hold time.
        final elapsed = DateTime.now().difference(_dragStartTime!);
        if (elapsed < kMinDragDuration) return;

        // Check if movement is predominantly vertical AND outside tab bar.
        final tabBarRect = _getTabBarScreenRect();
        if (tabBarRect != null &&
            delta.dy.abs() > delta.dx.abs() && // predominantly vertical
            _isOutsideTabBar(screenPos, tabBarRect)) {
          _enterDetachMode(screenPos);
        } else {
          // Horizontal or small vertical - let ReorderableListView handle it.
          _state = TabDragState.reordering;
        }

      case TabDragState.reordering:
        // User was reordering horizontally but may now drag vertically.
        final tabBarRect = _getTabBarScreenRect();
        if (tabBarRect != null && _isOutsideTabBar(screenPos, tabBarRect)) {
          _enterDetachMode(screenPos);
        }
        // Horizontal reorder is handled by ReorderableListView, not us.

      case TabDragState.idle:
      case TabDragState.detaching:
        break;
    }
  }

  /// Returns true if [screenPos] is far enough outside the tab bar bounds.
  bool _isOutsideTabBar(Offset screenPos, Rect tabBarRect) {
    return screenPos.dy > tabBarRect.bottom + kVerticalDetachThreshold ||
        screenPos.dy < tabBarRect.top - kVerticalDetachThresholdUp;
  }

  void _enterDetachMode(Offset screenPosition) {
    // Multi-window shelved - cancel drag instead of detaching
    _cleanup();
  }

  void onPointerUp(PointerUpEvent event) => _cleanup();
  void onPointerCancel(PointerCancelEvent event) => _cleanup();

  void _cleanup() {
    _state = TabDragState.idle;
    _draggedTabIndex = null;
    _dragStartScreen = null;
    _dragStartTime = null;
    onDragEnd?.call();
  }

  void dispose() => _cleanup();
}
