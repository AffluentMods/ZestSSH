import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/security/lock_art.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Whether the lock screen is what the app shows: its lock is on, or its database
/// is not open yet (the encrypting lock), as the router has it.
final lockScreenUpProvider = Provider<bool>((ref) => ref.watch(isAppLockedProvider) || !ref.watch(dbReadyProvider));

/// How long the doors take to split open onto the app, all told (under half a
/// second: the check is done before they move, so they never slow the unlock).
const kLockOpenTime = Duration(milliseconds: 480);

/// How long the doors take to close over the app when its person locks it.
const kLockCloseTime = Duration(milliseconds: 280);

/// With reduce motion: a short fade in place of the doors.
const kLockFadeTime = Duration(milliseconds: 180);

const _kCardInTime = Duration(milliseconds: 220);

enum _Phase { open, closing, locked, opening }

/// The lock screen's doors over the whole app (4.0).
/// While the app is locked they are shut, the art of the lock on
/// both halves, and the lock screen is drawn on them; the app's routes under them
/// hold only a backdrop ([LockBackdrop]), so nothing of the app is drawn, reachable
/// or read out before the check passes. Once it passes, the screen splits along a
/// curved seam and the halves slide apart onto the app; when its person locks it
/// (Lock ZestSSH) they close over it first, and it locks behind them. Any key or
/// click skips the motion, and with reduce motion it is a short fade. A lock that
/// comes by itself (idle, the computer, back from the background, the start) is
/// shut at once: the app is not shown on the way.
class LockCurtain extends ConsumerStatefulWidget {
  const LockCurtain({super.key, required this.child});

  /// The app: the router's pages.
  final Widget child;

  static _LockCurtainState? _current;

  /// Whether a curtain is up at the app's root. The lock route then shows only a
  /// backdrop under it; with none (a page built without the app's root) the route
  /// shows the lock screen itself.
  static bool get isUp => _current?.mounted ?? false;

  /// Locks ZestSSH as its person asked: the doors close over the app and it locks
  /// behind them, at once where no curtain is up. Nothing where the app lock is
  /// off: a lock with nothing to open it again.
  static Future<void> lockByYou(WidgetRef ref) async {
    if (!ref.read(settingsServiceProvider).securityLockEnabled || ref.read(isAppLockedProvider)) return;
    if (await ref.read(securityLockServiceProvider).getLockMethod() == SecurityLockMethod.none) return;
    final curtain = _current;
    if (curtain != null && curtain.mounted && curtain._phase == _Phase.open) {
      await curtain._closeThenLock();
    } else {
      await ref.read(isAppLockedProvider.notifier).lock(AppLockReason.byYou);
    }
  }

  @override
  ConsumerState<LockCurtain> createState() => _LockCurtainState();
}

class _LockCurtainState extends ConsumerState<LockCurtain> with TickerProviderStateMixin {
  late final _closing = AnimationController(vsync: this, duration: kLockCloseTime);
  late final _opening = AnimationController(vsync: this, duration: kLockOpenTime);
  late final _cardIn = AnimationController(vsync: this, duration: _kCardInTime, value: 1);
  final _focus = FocusNode(debugLabel: 'lock-curtain', skipTraversal: true);

  late _Phase _phase;

  /// The motion now running is the short fade of reduce motion.
  bool _still = false;

  /// The doors were closed by the person's lock: the seam's glow fades as the
  /// lock screen comes in.
  bool _sealed = false;

  /// A new lock screen for each lock.
  int _generation = 0;

  Completer<void>? _closed;

  @override
  void initState() {
    super.initState();
    LockCurtain._current = this;
    _phase = ref.read(lockScreenUpProvider) ? _Phase.locked : _Phase.open;
    _closing.addStatusListener((status) {
      if (status == AnimationStatus.completed) _closed?.complete();
    });
    _opening.addStatusListener((status) {
      if (status == AnimationStatus.completed && _phase == _Phase.opening && mounted) {
        setState(() => _phase = _Phase.open);
      }
    });
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    if (LockCurtain._current == this) LockCurtain._current = null;
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (!(_closed?.isCompleted ?? true)) _closed!.complete();
    _closing.dispose();
    _opening.dispose();
    _cardIn.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onLockChanged(bool? was, bool up) {
    if (!mounted) return;
    if (up) {
      // Locked: the doors are shut, by the motion that brought them or at once,
      // and the lock screen comes in on them.
      if (_phase == _Phase.locked) return;
      _still = MediaQuery.disableAnimationsOf(context);
      _sealed = _phase == _Phase.closing;
      _closing.stop();
      _opening.stop();
      // A lock that came by itself while the person's doors were closing: they
      // are shut now.
      if (!(_closed?.isCompleted ?? true)) _closed!.complete();
      setState(() {
        _phase = _Phase.locked;
        _generation++;
      });
      _cardIn
        ..duration = _still ? const Duration(milliseconds: 150) : _kCardInTime
        ..forward(from: 0);
    } else if (_phase == _Phase.locked) {
      // The check passed: the doors open onto the app.
      _still = MediaQuery.disableAnimationsOf(context);
      _cardIn.value = 1;
      setState(() => _phase = _Phase.opening);
      _opening
        ..duration = _still ? kLockFadeTime : kLockOpenTime
        ..forward(from: 0);
    }
  }

  /// The person's lock: the doors close over the app (which takes nothing more
  /// meanwhile), then it locks behind them. Should the lock not take, nothing is
  /// left over the app.
  Future<void> _closeThenLock() async {
    _still = MediaQuery.disableAnimationsOf(context);
    final closed = Completer<void>();
    _closed = closed;
    setState(() => _phase = _Phase.closing);
    _focus.requestFocus();
    _closing
      ..duration = _still ? kLockFadeTime : kLockCloseTime
      ..forward(from: 0);
    await closed.future;
    if (!mounted) return;
    try {
      await ref.read(isAppLockedProvider.notifier).lock(AppLockReason.byYou);
    } finally {
      if (mounted && _phase == _Phase.closing) setState(() => _phase = _Phase.open);
    }
  }

  /// A key or a click while the doors move: they are where they were going.
  void _skip() {
    if (_closing.isAnimating) _closing.value = 1;
    if (_opening.isAnimating) _opening.value = 1;
    if (_cardIn.isAnimating) _cardIn.value = 1;
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && (_closing.isAnimating || _opening.isAnimating || _cardIn.isAnimating)) _skip();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(lockScreenUpProvider, _onLockChanged);
    final phase = _phase;
    final theme = Theme.of(context);
    // While the doors are shut or opening the app's pages change without their
    // own transition (the lock's backdrop to the app, under the doors): the doors
    // are the motion.
    final pages = phase == _Phase.locked || phase == _Phase.opening
        ? theme.copyWith(pageTransitionsTheme: _kNoPageTransitions)
        : theme;
    final app = AnimatedBuilder(
      animation: _opening,
      builder: (context, child) {
        var scale = 1.0;
        var opacity = 1.0;
        if (phase == _Phase.opening && !_still) {
          // The app comes up from under the doors: a touch small and dim, to whole.
          final t = _appIn.transform(_opening.value);
          scale = 0.985 + 0.015 * t;
          opacity = 0.6 + 0.4 * t;
        }
        return Opacity(opacity: opacity, child: Transform.scale(scale: scale, child: child));
      },
      child: Theme(data: pages, child: widget.child),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(excluding: phase != _Phase.open, child: app),
        if (phase != _Phase.open) Positioned.fill(child: _layer(context, phase)),
      ],
    );
  }

  Widget _layer(BuildContext context, _Phase phase) {
    final phone = isTouchLayout;
    final art = LockArt(panel: ZestTokens.surfacePanel, accent: ZestTokens.brand, phone: phone);
    final accent = ZestTokens.brand;
    final card = phase == _Phase.locked || phase == _Phase.opening
        ? KeyedSubtree(
            key: ValueKey(_generation),
            child: IgnorePointer(
              ignoring: phase != _Phase.locked,
              child: ExcludeFocus(
                excluding: phase != _Phase.locked,
                child: HeroControllerScope.none(
                  child: Navigator(
                    onGenerateInitialRoutes: (navigator, initialRoute) => [
                      PageRouteBuilder<void>(
                        settings: const RouteSettings(name: 'lock'),
                        opaque: false,
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (context, animation, secondary) => const SecurityLockScreen(drawsArt: false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : null;
    return BlockSemantics(
      child: Listener(
        // A click skips the motion, and reaches nothing behind the doors.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _skip(),
        child: Focus(
          focusNode: _focus,
          child: LayoutBuilder(
            builder: (context, box) => AnimatedBuilder(
              animation: Listenable.merge([_closing, _opening, _cardIn]),
              child: card,
              builder: (context, card) {
                final width = box.maxWidth;
                // How far each door stands off its place, in widths; the seam's glow
                // and how much of it is drawn; the lock screen's fade; and with reduce
                // motion the whole layer's fade.
                var apart = 0.0;
                var seamDrawn = 1.0;
                var seamGlow = 0.0;
                var cardShown = 1.0;
                var cardScale = 1.0;
                var cardRise = 0.0;
                var layer = 1.0;
                switch (phase) {
                  case _Phase.closing:
                    if (_still) {
                      layer = _closing.value;
                    } else {
                      apart = 1.02 * (1 - _doorsShut.transform(_closing.value));
                      seamGlow = const Interval(0.5, 1).transform(_closing.value);
                    }
                  case _Phase.locked:
                    final t = Curves.easeOut.transform(_cardIn.value);
                    cardShown = t;
                    if (!_still) cardRise = 6 * (1 - t);
                    if (_sealed && !_still) seamGlow = 1 - const Interval(0, 0.6).transform(_cardIn.value);
                  case _Phase.opening:
                    final t = _opening.value;
                    if (_still) {
                      layer = 1 - t;
                    } else {
                      final out = _cardOut.transform(t);
                      cardShown = 1 - out;
                      cardScale = 1 - 0.03 * out;
                      seamDrawn = _seamDraw.transform(t);
                      seamGlow = _seamGlow(t);
                      apart = 1.02 * _doorsApart.transform(t);
                    }
                  case _Phase.open:
                    break;
                }
                return Opacity(
                  opacity: layer.clamp(0.0, 1.0),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform.translate(
                        offset: Offset(-apart * width, 0),
                        child: RepaintBoundary(child: ClipPath(clipper: const LockDoorClipper(left: true), child: art)),
                      ),
                      Transform.translate(
                        offset: Offset(apart * width, 0),
                        child: RepaintBoundary(child: ClipPath(clipper: const LockDoorClipper(left: false), child: art)),
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: LockSeamPainter(accent: accent, drawn: seamDrawn, opacity: seamGlow),
                        ),
                      ),
                      if (card != null)
                        Opacity(
                          opacity: cardShown.clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(0, cardRise),
                            child: Transform.scale(scale: cardScale, child: card),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // The opening, as parts of its 480 ms: the lock screen fades out (0 to 130),
  // the seam is drawn down (30 to 190) and glows (20 to 420), the doors slide
  // apart (170 to 470) and the app comes up under them (170 to the end).
  static const _cardOut = Interval(0, 130 / 480, curve: Curves.easeIn);
  static const _seamDraw = Interval(30 / 480, 190 / 480, curve: Curves.easeOut);
  static const _doorsApart = Interval(170 / 480, 470 / 480, curve: Cubic(0.65, 0, 0.25, 1));
  static const _appIn = Interval(170 / 480, 1, curve: Cubic(0.2, 0.8, 0.2, 1));
  static const _doorsShut = Cubic(0.2, 0.8, 0.2, 1);

  static double _seamGlow(double t) {
    final g = const Interval(20 / 480, 420 / 480).transform(t);
    if (g <= 0) return 0;
    if (g < 0.2) return g / 0.2;
    if (g < 0.6) return 1;
    return (1 - g) / 0.4;
  }
}

/// The app's pages change with no transition of their own while the doors are
/// shut or opening.
final _kNoPageTransitions = PageTransitionsTheme(builders: {
  for (final platform in TargetPlatform.values) platform: const _NoPageTransition(),
});

class _NoPageTransition extends PageTransitionsBuilder {
  const _NoPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}

/// What the lock route shows: under the curtain only the panel's colour, with
/// back held (the curtain draws the lock screen on its doors). Where no curtain
/// is up, the lock screen itself.
class LockBackdrop extends StatelessWidget {
  const LockBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    if (!LockCurtain.isUp) return const SecurityLockScreen();
    return PopScope(
      canPop: false,
      child: ColoredBox(color: ZestTokens.surfacePanel, child: const SizedBox.expand()),
    );
  }
}
