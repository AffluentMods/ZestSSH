import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

/// The docked, resizable New/Edit connection editor.
///
/// Unlike the old `showGeneralDialog` overlay, this is a plain layout SIBLING
/// of the desktop shell's content [Row] - so it PUSHES/SHRINKS the main
/// content rather than floating over it behind a scrim. It
/// mirrors [HostSlideOutPanel] on the opposite (right) edge:
///   • a panel as wide as [connectionEditorWidthProvider] asks, less where the
///     window is narrow (the shell lays it out: [connectionEditorFit]), and
///   • a left-edge [_ResizeHandle] that drags to resize.
///
/// Because it has NO barrier/scrim, clicking the host list behind it does
/// nothing (it isn't modal) - the editor is dismissed only via its own
/// close ✕ / Cancel / save, which route through [ConnectionEditScreen.onClose]
/// back to [connectionEditorTargetProvider].
class ConnectionEditorDock extends ConsumerWidget {
  const ConnectionEditorDock({super.key, required this.target, this.fill = false});

  /// Which connection the dock is editing (null id = a new connection).
  final ConnectionEditorTarget target;

  /// As wide as its parent makes it, its handle included (the shell's, which
  /// gives it the width asked for, or less where the window is narrow:
  /// [connectionEditorFit]); the width asked for where false.
  final bool fill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = ref.watch(connectionEditorWidthProvider);
    return Row(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // Left-edge handle. The panel is docked on the RIGHT, so dragging the
        // handle LEFT (negative dx) must GROW the panel: next = width - dx.
        // From the width on screen, which can be less than the one asked for
        // where the window is narrow.
        _ResizeHandle(
          onDrag: (dx) {
            final box = context.findRenderObject() as RenderBox?;
            final shownWidth = box != null && box.hasSize
                ? box.size.width - kConnectionEditorHandleWidth
                : ref.read(connectionEditorWidthProvider);
            final next = (shownWidth - dx).clamp(
              kConnectionEditorMinWidth,
              kConnectionEditorMaxWidth,
            );
            ref.read(connectionEditorWidthProvider.notifier).state = next;
          },
        ),
        // Its own focus scope: Tab walks the editor's fields and wraps around
        // inside the panel instead of wandering into the host grid or the
        // sidebar beside it (reading-order traversal spans the window).
        _Fill(
          fill: fill,
          width: width,
          child: FocusScope(
          debugLabel: 'ConnectionEditorDock',
          child: SizedBox(
            width: fill ? null : width,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.v3Background,
                border: Border(
                  left: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
                ),
              ),
              child: ConnectionEditScreen(
                // A fresh State per target so switching connections (or new
                // → edit) rebuilds the form from scratch instead of keeping
                // the previous connection's field values.
                key: ValueKey(target.connectionId ??
                    'new_${target.initialHost ?? ''}_${target.initialPort ?? ''}_${target.initialLabel ?? ''}'),
                connectionId: target.connectionId,
                initialProtocol: target.initialProtocol,
                initialHost: target.initialHost,
                initialPort: target.initialPort,
                initialLabel: target.initialLabel,
                initialSection: target.initialSection,
                initialVia: target.initialVia,
                inDialog: true,
                onClose: () => ref
                    .read(connectionEditorTargetProvider.notifier)
                    .state = null,
              ),
            ),
          ),
        ),
        ),
      ],
    );
  }
}

/// The panel beside its handle: the rest of the dock's width where it fills
/// its parent, else [width] wide.
class _Fill extends StatelessWidget {
  const _Fill({required this.fill, required this.width, required this.child});

  final bool fill;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => fill ? Expanded(child: child) : SizedBox(width: width, child: child);
}

/// The width of the panel's drag handle, at its left edge.
const double kConnectionEditorHandleWidth = 6;

/// The least width the Hosts page keeps beside the docked editor: its toolbar
/// on two rows (the buttons and the filter field, then the views, Sort and
/// Filter) and the empty page's cards whole (the device run of 13 November
/// 2026, where a 1200 wide window left it 290 and the toolbar took three rows).
const double kHostsPageMinWidth = 520;

/// Where the editor goes in a content area [room] wide, the panel asked to be
/// [wanted] wide: beside the page, as wide as asked where the page keeps
/// [kHostsPageMinWidth], narrower down to [kConnectionEditorMinWidth] where it
/// would not; where even that leaves the page too little, over the page at the
/// width asked (never wider than the area). [width] is the panel's, without
/// its handle.
({double width, bool docked}) connectionEditorFit(double room, double wanted) {
  final beside = room - kHostsPageMinWidth - kConnectionEditorHandleWidth;
  if (beside >= kConnectionEditorMinWidth) {
    return (width: wanted < beside ? wanted : beside, docked: true);
  }
  final over = room - kConnectionEditorHandleWidth;
  return (width: wanted < over ? wanted : (over > 0 ? over : 0), docked: false);
}

/// Thin drag handle on the panel's left edge. Reports horizontal deltas; the
/// caller clamps the resulting width. (Mirrors host_slide_out_panel's handle
/// but with no persistence - the docked editor width is session-only.)
class _ResizeHandle extends StatelessWidget {
  final void Function(double dx) onDrag;

  const _ResizeHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: const SizedBox(width: kConnectionEditorHandleWidth, height: double.infinity),
      ),
    );
  }
}
