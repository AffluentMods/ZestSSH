import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart' show sharedPreferencesProvider;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

/// How big the app's controls are (4.0):
/// touch sized, a finger's 48 to a row and a button
/// (Comfortable), or a computer's tighter sizes for a mouse (Compact). Auto
/// follows the input: a phone and a tablet are touch sized until a mouse or a
/// trackpad is used on them, and a computer is compact until it is touched
/// (a 2-in-1's screen), each until the other input is used again.
enum UiDensity {
  auto,
  comfortable,
  compact;

  static UiDensity parse(String? name) => values.where((d) => d.name == name).firstOrNull ?? auto;

  String nameIn(AppLocalizations l10n) => switch (this) {
    auto => l10n.densityAuto,
    comfortable => l10n.densityComfortable,
    compact => l10n.densityCompact,
  };
}

/// The setting's key in the store (Settings, Appearance; reset by Reset all
/// settings).
const kUiDensityKey = 'ui_density';

/// The density picked in Settings.
final uiDensityProvider = StateProvider<UiDensity>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return UiDensity.parse(prefs.getString(kUiDensityKey));
});

/// Keeps [density] and shows it at once.
Future<void> setUiDensity(WidgetRef ref, UiDensity density) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setString(kUiDensityKey, density.name);
  ref.read(uiDensityProvider.notifier).state = density;
}

/// The kind of pointer last pressed in the app: a finger (or a pen), or a
/// mouse or a trackpad. Null until one is ([PointerInputTracker]).
final lastPointerKindProvider = StateProvider<PointerDeviceKind?>((_) => null);

/// Whether a pointer of [kind] is a finger's or a pen's, which want touch
/// sized controls.
bool isTouchPointer(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.invertedStylus;

/// Whether the app's controls are touch sized now: the setting, and for Auto
/// the input last used (before any, the device's kind).
final touchSizedProvider = Provider<bool>((ref) {
  switch (ref.watch(uiDensityProvider)) {
    case UiDensity.comfortable:
      return true;
    case UiDensity.compact:
      return false;
    case UiDensity.auto:
      final kind = ref.watch(lastPointerKindProvider);
      return kind == null ? isTouchLayout : isTouchPointer(kind);
  }
});

/// Whether the extras of a mouse or a trackpad are on: hovers' tooltips and
/// highlights, a right click's menu. They are extras: each right click's
/// menu is also under a long press and a visible more button, and nothing
/// shows only under a hovering pointer. On a phone and a tablet only once a
/// mouse or a trackpad was used; on a computer always.
final mouseExtrasProvider = Provider<bool>((ref) {
  final kind = ref.watch(lastPointerKindProvider);
  if (kind == null) return !isTouchLayout;
  return !isTouchPointer(kind);
});

/// Hears every press of a pointer in the app, before anything takes it, and
/// keeps its kind ([lastPointerKindProvider]) when it changes. The app's root
/// holds one.
class PointerInputTracker extends ConsumerStatefulWidget {
  const PointerInputTracker({super.key, required this.child});

  final Widget child;

  /// Whether the tracker hears pointers. Off in tests unless one turns it on
  /// (test/flutter_test_config.dart): a test's taps are a finger's, which
  /// would make a computer's pages touch sized under it.
  static bool enabled = true;

  @override
  ConsumerState<PointerInputTracker> createState() => _PointerInputTrackerState();
}

class _PointerInputTrackerState extends ConsumerState<PointerInputTracker> {
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (!PointerInputTracker.enabled) return;
        final notifier = ref.read(lastPointerKindProvider.notifier);
        final was = notifier.state;
        // A pen counts as a finger, and a trackpad as a mouse: only a change
        // between the two is kept, so the app is not rebuilt at each press.
        if (was != null && isTouchPointer(was) == isTouchPointer(event.kind)) return;
        notifier.state = event.kind;
      },
      child: widget.child,
    );
  }
}

/// Whether the app's controls are touch sized where [context] is: the theme
/// says ([ZestDensity]); without it, the device's kind.
bool touchSizedAt(BuildContext context) => Theme.of(context).extension<ZestDensity>()?.touch ?? isTouchLayout;

/// The theme's density ([touchSizedProvider] when the theme was made).
@immutable
class ZestDensity extends ThemeExtension<ZestDensity> {
  const ZestDensity({required this.touch});

  /// Touch sized: 48 to a row, a tab and a target.
  final bool touch;

  /// A touch target's least size.
  double get target => touch ? 48 : 34;

  @override
  ZestDensity copyWith({bool? touch}) => ZestDensity(touch: touch ?? this.touch);

  @override
  ZestDensity lerp(ZestDensity? other, double t) => t < 0.5 || other == null ? this : other;
}
