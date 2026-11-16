/// Swiping between a phone's sessions (3.1):
/// a sideways swipe on the terminal's top bar moves to the previous or
/// the next open session, in the order the Sessions tab lists them, as a
/// browser's tabs. Never a swipe across the terminal itself, which keeps its
/// text selection, its scrolling in less or htop, and tmux. The new session
/// slides in from the side the swipe went to and says its name for a moment;
/// with no session on that side the bar gives a small bounce.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/host_address.dart' show hostWithPort;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

/// Whether a terminal's top bar swipes between sessions: on a phone (a
/// screen narrower than a tablet's). A computer and a tablet keep their bar
/// as it was.
bool sessionSwipeOn(BuildContext context) => isTouchLayout && MediaQuery.sizeOf(context).shortestSide < 600;

/// Whether the phone's Sessions tab lists [s]: live ones, and ones that
/// dropped, so they can be reconnected or cleared from there.
bool listedInSessionsTab(SessionState s) =>
    s.status == SessionStatus.connecting ||
    s.status == SessionStatus.connected ||
    s.status == SessionStatus.disconnected;

/// The host the Sessions tab groups a session under: its [name], with its
/// [address] under it (the port where it is not 22). A host with no name
/// has an empty [name] and goes by its address alone.
typedef SessionsTabHost = ({String name, String address});

/// What the Sessions tab groups [s] under: its host by its name, with its
/// address under it (it used to group by the
/// address alone, a raw IP over each group). A host with no name goes by
/// its address, one with neither by [unknown].
SessionsTabHost sessionsTabHost(SessionState s, ConnectionWithDetails? conn, String unknown) {
  final host = (conn?.connection.host ?? s.host ?? '').trim();
  final port = conn?.connection.port ?? s.port ?? 22;
  final address = host.isEmpty || port == 22 ? host : hostWithPort(host, port);
  final label = (conn?.connection.label ?? s.connectionLabel).trim();
  if (label.isNotEmpty || address.isNotEmpty) return (name: label, address: address);
  return (name: unknown, address: '');
}

/// The sessions in the order the Sessions tab lists them: grouped by host,
/// the groups and the sessions in each in the order they were opened.
List<String> sessionsInTabOrder(
  Map<String, SessionState> sessions,
  List<ConnectionWithDetails>? connections, {
  required String unknown,
}) {
  final byId = {for (final c in connections ?? const <ConnectionWithDetails>[]) c.connection.id: c};
  final groups = <SessionsTabHost, List<String>>{};
  for (final entry in sessions.entries) {
    if (!listedInSessionsTab(entry.value)) continue;
    final connId = entry.value.connectionId ?? entry.value.session?.connectionId;
    final key = sessionsTabHost(entry.value, connId == null ? null : byId[connId], unknown);
    (groups[key] ??= []).add(entry.key);
  }
  return [for (final ids in groups.values) ...ids];
}

/// How a session was reached by a swipe: 1 from the next one's side (a
/// swipe to the left), -1 from the previous one's (a swipe to the right).
/// The terminal's route takes it as its `extra`.
class SessionSwipe {
  const SessionSwipe(this.direction);

  final int direction;
}

/// The terminal's top bar, swiped sideways to move between sessions.
class SessionSwipeHeader extends ConsumerStatefulWidget {
  const SessionSwipeHeader({super.key, required this.sessionId, required this.child});

  final String sessionId;
  final Widget child;

  @override
  ConsumerState<SessionSwipeHeader> createState() => _SessionSwipeHeaderState();
}

class _SessionSwipeHeaderState extends ConsumerState<SessionSwipeHeader> with SingleTickerProviderStateMixin {
  /// How far the finger has dragged the bar; the bar follows it a third of
  /// the way, as a band of rubber.
  double _drag = 0;

  late final AnimationController _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 320))
    ..addListener(() => setState(() {}));
  Animation<double>? _settling;

  /// A swipe this far (or this fast) moves to the session beside.
  static const _distance = 48.0;
  static const _speed = 500.0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  List<String> _order() => sessionsInTabOrder(
        ref.read(activeSessionsProvider),
        ref.read(connectionsWithDetailsProvider).valueOrNull,
        unknown: AppLocalizations.of(context)!.homeUnknown,
      );

  /// The session beside this one, [direction] 1 the next, -1 the previous.
  String? _beside(int direction) {
    final order = _order();
    final at = order.indexOf(widget.sessionId);
    if (at < 0) return null;
    final to = at + direction;
    return to >= 0 && to < order.length ? order[to] : null;
  }

  void _go(int direction) {
    final to = _beside(direction);
    if (to == null) {
      _bounce(direction);
      return;
    }
    haptic(ref, Haptic.light);
    setState(() => _drag = 0);
    context.pushReplacement('/terminal/$to', extra: SessionSwipe(direction));
  }

  /// No session on that side: the bar goes a little way and comes back.
  void _bounce(int direction) {
    final from = _drag;
    final out = -direction * 42.0;
    _settling = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: from, end: out).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
      TweenSequenceItem(tween: Tween(begin: out, end: 0.0).chain(CurveTween(curve: Curves.easeOutBack)), weight: 65),
    ]).animate(_settle);
    _drag = 0;
    _settle.forward(from: 0);
  }

  /// A swipe too short: the bar goes back.
  void _back() {
    _settling = Tween<double>(begin: _drag, end: 0).chain(CurveTween(curve: Curves.easeOut)).animate(_settle);
    _drag = 0;
    _settle.forward(from: 0);
  }

  void _onEnd(DragEndDetails details) {
    final speed = details.primaryVelocity ?? 0;
    final dx = _drag;
    if (dx.abs() >= _distance || speed.abs() >= _speed) {
      // Dragged to the left: the next session, as a browser's tabs.
      final leftwards = dx.abs() >= _distance ? dx < 0 : speed < 0;
      _go(leftwards ? 1 : -1);
    } else {
      _back();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shift = (_settle.isAnimating ? (_settling?.value ?? 0) : _drag) / 3;
    // A screen reader's swipes are its own: the same moves as two actions.
    ref.watch(activeSessionsProvider);
    final previous = _beside(-1);
    final next = _beside(1);
    return Semantics(
      customSemanticsActions: {
        if (previous != null) CustomSemanticsAction(label: l10n.sessionSwipePrevious): () => _go(-1),
        if (next != null) CustomSemanticsAction(label: l10n.sessionSwipeNext): () => _go(1),
      },
      child: GestureDetector(
        key: const ValueKey('session-swipe-header'),
        onHorizontalDragStart: (_) {
          _settle.stop();
          _drag = 0;
        },
        onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(-160.0, 160.0)),
        onHorizontalDragEnd: _onEnd,
        onHorizontalDragCancel: _back,
        child: Transform.translate(
          key: const ValueKey('session-swipe-shift'),
          offset: Offset(shift, 0),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The page of a session reached by a swipe: it slides in from the side the
/// swipe went to; after that it is a page as any other (on an iPhone, the
/// swipe from the screen's left edge back to Home included).
class SessionSwipePage extends Page<void> {
  const SessionSwipePage({
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    required this.direction,
    required this.sessionId,
    required this.child,
  });

  final int direction;
  final String sessionId;
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _SessionSwipeRoute(this);
}

class _SessionSwipeRoute extends PageRoute<void> with MaterialRouteTransitionMixin<void> {
  _SessionSwipeRoute(SessionSwipePage page) : super(settings: page);

  SessionSwipePage get _page => settings as SessionSwipePage;

  /// Whether the slide in is over.
  bool _arrived = false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  TickerFuture didPush() {
    animation!.addStatusListener(_status);
    return super.didPush();
  }

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.completed || _arrived) return;
    _arrived = true;
    animation!.removeStatusListener(_status);
    changedInternalState();
  }

  @override
  Widget buildContent(BuildContext context) =>
      SessionArrivalName(sessionId: _page.sessionId, child: _page.child);

  @override
  Widget buildTransitions(
      BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (_arrived) return super.buildTransitions(context, animation, secondaryAnimation, child);
    return SlideTransition(
      position: Tween<Offset>(begin: Offset(_page.direction.toDouble(), 0), end: Offset.zero)
          .chain(CurveTween(curve: Curves.easeOutCubic))
          .animate(animation),
      child: child,
    );
  }

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

/// A session reached by a swipe says its name, and which of the open ones it
/// is, for a moment under the top bar.
class SessionArrivalName extends ConsumerStatefulWidget {
  const SessionArrivalName({super.key, required this.sessionId, required this.child});

  final String sessionId;
  final Widget child;

  @override
  ConsumerState<SessionArrivalName> createState() => _SessionArrivalNameState();
}

class _SessionArrivalNameState extends ConsumerState<SessionArrivalName> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 20),
  ]).animate(_fade);

  @override
  void initState() {
    super.initState();
    _fade.forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.watch(activeSessionsProvider);
    final s = sessions[widget.sessionId];
    final order = sessionsInTabOrder(sessions, ref.watch(connectionsWithDetailsProvider).valueOrNull,
        unknown: l10n.homeUnknown);
    final at = order.indexOf(widget.sessionId);
    final name = s == null ? '' : (s.connectionLabel.trim().isNotEmpty ? s.connectionLabel : (s.host ?? ''));
    return Stack(
      children: [
        widget.child,
        if (s != null)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 56,
            left: 24,
            right: 24,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _fade,
                builder: (context, child) => _fade.isCompleted ? const SizedBox.shrink() : Opacity(opacity: _opacity.value, child: child),
                child: Center(
                  child: DecoratedBox(
                    key: const ValueKey('session-arrival-name'),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceDark.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RedactedText(
                            Redactable.host(name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          if (at >= 0 && order.length > 1)
                            Text(
                              l10n.sessionSwipePosition(at + 1, order.length),
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                            ),
                        ],
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
