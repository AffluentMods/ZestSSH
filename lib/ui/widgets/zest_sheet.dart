import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';
import 'package:zestssh/ui/widgets/zest_in_place.dart';

/// Sheets on phones (3.0 UI): on a phone, the app's
/// dialogs open as bottom sheets with full-width buttons, in reach of a
/// thumb. Tablets and desktops keep centred dialogs.
bool zestUsesSheets(BuildContext context) {
  final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  return mobile && MediaQuery.sizeOf(context).shortestSide < 600;
}

/// Marks what is inside a bottom sheet, so a dialog's frame draws as a sheet
/// (rounded top, a handle, buttons across the width).
class ZestSheetScope extends InheritedWidget {
  const ZestSheetScope({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ZestSheetScope>() != null;

  @override
  bool updateShouldNotify(ZestSheetScope oldWidget) => false;
}

/// Opens [child] (a dialog widget that knows [ZestSheetScope]) as a bottom
/// sheet, above the keyboard. [dismissible]: a tap outside or a drag down
/// closes it. [useRootNavigator]: on the app's own navigator, over every
/// nested one (as a dialog is by default).
Future<T?> showZestSheet<T>({
  required BuildContext context,
  required Widget child,
  bool dismissible = true,
  bool useRootNavigator = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    useSafeArea: true,
    // The frame draws its own handle, on its own surface.
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    isDismissible: dismissible,
    enableDrag: dismissible,
    builder: (context) => ZestSheetScope(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        // A follow-up shows in this sheet's place (showZestInPlace).
        child: ZestInPlaceHost(child: child),
      ),
    ),
  );
}

/// A dialog's card drawn as a sheet: the elevated surface with a rounded
/// top and a handle, as tall as its content up to most of the screen.
class ZestSheetFrame extends StatelessWidget {
  const ZestSheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.92;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        key: const ValueKey('zest-sheet'),
        decoration: BoxDecoration(
          color: AppColors.v3Elevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.v3BorderStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Ink inside draws on the sheet, not on the Material under it.
              Flexible(child: InkLayer(child: child)),
            ],
          ),
        ),
      ),
    );
  }
}
