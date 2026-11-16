import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_surfaces.dart' show readableShade;
import 'package:zestssh/theme/zest_tokens.dart';

// What the app's shared controls do for people who use a screen reader, a
// keyboard alone, large text or less motion (4.0):
// one place for each rule, so every control keeps it. A
// control's least target is zest_pressable.dart's [minTapTarget] (48 where
// the app is touch sized, 32 otherwise), and a hand-drawn button is a
// ZestPressable there.

/// The system asks for less motion (reduce motion on iOS and macOS, remove
/// animations on Android and Windows): nothing slides, shakes or pulses.
bool zestReduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// [duration], or none where the system asks for less motion.
Duration zestMotion(BuildContext context, Duration duration) =>
    zestReduceMotion(context) ? Duration.zero : duration;


/// Says [message] to a screen reader now (an error that came up, a message
/// that showed, a terminal's new lines): VoiceOver, TalkBack, Narrator and
/// Orca read it out. Where the platform says it takes no announcements
/// ([MediaQueryData.supportsAnnounce] false: Android deprecated them), the
/// words go for a few seconds into a live region over everything, which
/// TalkBack reads when it appears.
void zestAnnounce(BuildContext context, String message, {Assertiveness assertiveness = Assertiveness.polite}) {
  final text = message.trim();
  if (text.isEmpty) return;
  final media = MediaQuery.maybeOf(context);
  if (media == null || media.supportsAnnounce) {
    final view = View.maybeOf(context);
    if (view == null) return;
    unawaited(SemanticsService.sendAnnouncement(
      view,
      text,
      Directionality.maybeOf(context) ?? TextDirection.ltr,
      assertiveness: assertiveness,
    ));
    return;
  }
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay != null) _LiveRegion.say(overlay, text);
}

/// What is being said goes, at once: a terminal's lines can be a person's,
/// and a change of profile forgets them (forgetWhatLivesOutsideTheAppState).
void forgetAnnouncements() => _LiveRegion._remove();

/// The one live region an app's root overlay holds while it has something to
/// say: a new message replaces the one before, and it goes after a few
/// seconds, so a screen reader that moves through the screen never finds it.
class _LiveRegion {
  static OverlayEntry? _entry;
  static OverlayState? _overlay;
  static final _text = ValueNotifier<String>('');
  static Timer? _gone;

  static void say(OverlayState overlay, String text) {
    if (_entry == null || _overlay != overlay || !overlay.mounted) {
      _remove();
      _overlay = overlay;
      _entry = OverlayEntry(
        builder: (_) => IgnorePointer(
          child: ValueListenableBuilder<String>(
            valueListenable: _text,
            builder: (_, value, _) => Semantics(
              liveRegion: true,
              label: value,
              child: const SizedBox(width: 1, height: 1),
            ),
          ),
        ),
      );
      overlay.insert(_entry!);
    }
    // The same words twice in a row are a change TalkBack would not hear:
    // a space keeps them different and is not read.
    _text.value = _text.value == text ? '$text ' : text;
    _gone?.cancel();
    _gone = Timer(const Duration(seconds: 6), _remove);
  }

  static void _remove() {
    _gone?.cancel();
    _gone = null;
    final entry = _entry;
    _entry = null;
    _overlay = null;
    _text.value = '';
    if (entry != null && entry.mounted) entry.remove();
  }
}

/// The ring a control shows while the keyboard is on it: the accent, 2 wide,
/// [gap] outside the control, so showing it never moves anything.
class ZestFocusRing extends StatelessWidget {
  const ZestFocusRing({super.key, required this.show, required this.child, this.radius = 8, this.gap = 3});

  final bool show;
  final Widget child;

  /// The control's own corner radius; the ring's is [gap] more.
  final double radius;
  final double gap;

  /// The key the ring is drawn with (tests find it by this).
  static const ringKey = ValueKey('zest-focus-ring');

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        child,
        if (show)
          Positioned(
            left: -gap,
            top: -gap,
            right: -gap,
            bottom: -gap,
            child: IgnorePointer(
              child: DecoratedBox(
                key: ringKey,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius + gap),
                  border: Border.all(color: ZestTokens.brand, width: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The name of the setting or field a control stands for, given by the row
/// it stands in (a settings row's name): a switch, a select or a number field
/// in it is said to a screen reader with that name ("Bell, switch, on"), not
/// as a switch of nothing.
class ZestControlLabel extends InheritedWidget {
  const ZestControlLabel({super.key, required this.label, required super.child});

  final String label;

  /// The name given by the nearest row, or null.
  static String? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ZestControlLabel>()?.label;

  @override
  bool updateShouldNotify(ZestControlLabel oldWidget) => oldWidget.label != label;
}

/// [ink] as words on a fill of itself at [alpha] laid over any of the app's
/// surfaces (a tinted pill or badge: green words on a green wash): the
/// nearest shade of it that reads at 4.5:1 on every one of them. The wash
/// takes contrast away from the words on it; drawn in the colour as it is,
/// "This device" was 4.4:1 on Ember's card and a status 3:1 on others.
Color zestInkOnTint(Color ink, double alpha) {
  final tint = ink.withValues(alpha: alpha);
  final grounds = [
    for (final g in [
      AppColors.v3Background,
      AppColors.v3Surface,
      AppColors.v3Elevated,
      ZestTokens.surfaceBase,
      ZestTokens.surfaceRaised,
      ZestTokens.surfaceElevated,
      // A well and a menu hold washed pills too (the Keys page's chosen
      // filter was 4.48:1 on Daylight's well).
      ZestTokens.surfaceSunken,
      ZestTokens.surfaceRaisedAlt,
    ])
      Color.alphaBlend(tint, g),
  ];
  return readableShade(ink, grounds);
}

/// The accent as words or a glyph on the accent's own subtle wash (a tag, a
/// chosen chip): the nearest shade of it that reads there at 4.5:1. The
/// brand orange itself is 2.3:1 on Daylight's wash.
Color get zestBrandOnSubtle => zestInkOnTint(ZestTokens.brand, 0x1F / 0xFF);

/// Tells [onHover] when a mouse comes over [child] and leaves it. (A
/// FocusableActionDetector's hover highlight is not reported while the app
/// is in touch mode, which left a hovered row without its fill.)
class ZestHover extends StatelessWidget {
  const ZestHover({super.key, required this.onHover, required this.child});

  final ValueChanged<bool>? onHover;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: onHover == null ? null : (_) => onHover!(true),
        onExit: onHover == null ? null : (_) => onHover!(false),
        child: child,
      );
}
