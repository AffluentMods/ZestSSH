// Remote screens (4.0): the session panel, one for a computer and a
// phone. It slides in from the side over the picture and holds everything a
// screen's session can do, in the action list's groups (Session, Video,
// Input, Displays, Clipboard and files, Details), each option with a line
// that says what it does. It is drawn from the session's [ScreenMenuState]
// and names no action itself, so an action added to the list appears here.
//
// A switch or a choice acts at once and the panel stays open, showing the new
// state as the session reports it ([state] is listened to); an action done
// once (a key sent, a refresh, Disconnect) closes it first. An option that
// cannot be picked now is greyed, with the reason in place of its line.
// Disconnect and full screen sit at the top, as buttons.
//
// From the keyboard alone: the first option has the focus as it opens, Up
// and Down move between options (Tab and Shift+Tab as well), Enter or Space
// picks, Esc closes. A switch's row is one stop.
//
// Each group folds at its heading (a tap, or Enter on it), and this device
// remembers which are folded (this profile's SharedPreferences,
// screen_panel_folded: a layout
// of this device, put back by Reset all settings).
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/displays/screen_display_bars.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart' show sharedPreferencesProvider;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;
import 'package:zestssh/ui/widgets/zest_dialog.dart' show ZestChoice, showZestChoice;

/// The line under an option that says what it does, or null for one whose
/// words say it already.
String? screenActionHelpIn(AppLocalizations l10n, ScreenAction a, {bool phone = false}) => switch (a) {
      ScreenAction.fit => l10n.screenHelpFit,
      ScreenAction.fill => l10n.screenHelpFill,
      ScreenAction.oneToOne => l10n.screenHelpOneToOne,
      ScreenAction.remoteResize => l10n.screenHelpRemoteResize,
      ScreenAction.viewOnly => l10n.screenHelpViewOnly,
      ScreenAction.ownWindow => l10n.screenHelpOwnWindow,
      ScreenAction.refresh => l10n.screenHelpRefresh,
      ScreenAction.textSize => l10n.screenHelpTextSize,
      ScreenAction.frameLimit => l10n.screenHelpFrameLimit,
      ScreenAction.smoothScaling => l10n.screenHelpSmoothScaling,
      ScreenAction.sound => l10n.screenHelpSound,
      ScreenAction.touchPointer => l10n.screenHelpTouchPointer,
      ScreenAction.touchTouch => l10n.screenHelpTouchTouch,
      ScreenAction.sendText => l10n.screenHelpSendText,
      ScreenAction.sessionDetails => l10n.screenHelpSessionDetails,
      // A phone holds no pointer and has no menu key: a finger moves it.
      ScreenAction.relativeMouse => phone ? l10n.screenHelpRelativeMousePhone : l10n.screenHelpRelativeMouse,
      ScreenAction.commandAsControl => l10n.screenHelpCommandAsControl,
      ScreenAction.releaseKeyboard => l10n.screenHelpReleaseKeyboard,
      ScreenAction.clipboard => l10n.screenHelpClipboard,
      ScreenAction.pasteToRemote => l10n.screenHelpPasteToRemote,
      ScreenAction.keepBar => l10n.screenHelpKeepBar,
      ScreenAction.files => l10n.screenHelpFiles,
      _ => null,
    };

/// Whether picking [a] in the panel closes it: an action done once, full
/// screen (the window changes under the panel), and the session's details
/// (they are shown over the picture, where the panel is).
bool screenPanelClosesOn(ScreenAction a) =>
    a.kind == ScreenActionKind.plain || a == ScreenAction.fullScreen || a == ScreenAction.sessionDetails;

/// The width of the panel where the screen is [screenWidth] wide.
double screenPanelWidthFor(double screenWidth) => (screenWidth * 0.88).clamp(280.0, 380.0);

/// Opens the session panel over the screen, drawn from [state] as it changes.
/// [onAction] gets each pick; the panel closes before an action done once is
/// handed over.
Future<void> showScreenPanel(
  BuildContext context, {
  required ValueListenable<ScreenMenuState> state,
  required ValueChanged<ScreenAction> onAction,
  ScreenMenuKey menuKey = ScreenMenuKey.f8,
  ValueListenable<ScreenDisplays>? displays,
  ValueChanged<int?>? onDisplay,
}) {
  final l10n = AppLocalizations.of(context)!;
  final still = MediaQuery.disableAnimationsOf(context);
  final rtl = Directionality.of(context) == TextDirection.rtl;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: l10n.screenPanelTitle,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: still ? Duration.zero : const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: AlignmentDirectional.centerEnd,
      child: ScreenSessionPanel(
        state: state,
        menuKey: menuKey,
        displays: displays,
        onDisplay: onDisplay,
        onAction: (a) {
          if (screenPanelClosesOn(a)) {
            Navigator.of(dialogContext).pop();
          }
          onAction(a);
        },
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    ),
    transitionBuilder: (_, anim, _, child) => SlideTransition(
      position: Tween<Offset>(begin: Offset(rtl ? -1 : 1, 0), end: Offset.zero).animate(
        CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
      ),
      child: child,
    ),
  );
}

/// The panel itself, drawn from [state] as it changes.
class ScreenSessionPanel extends ConsumerStatefulWidget {
  const ScreenSessionPanel({
    super.key,
    required this.state,
    required this.onAction,
    required this.onClose,
    this.menuKey = ScreenMenuKey.f8,
    this.displays,
    this.onDisplay,
  });

  final ValueListenable<ScreenMenuState> state;

  /// The remote's displays, shown as choices in the Displays group when there
  /// are several; a pick goes to [onDisplay] (null: all of them) and keeps the
  /// panel open.
  final ValueListenable<ScreenDisplays>? displays;
  final ValueChanged<int?>? onDisplay;
  final ValueChanged<ScreenAction> onAction;
  final VoidCallback onClose;
  final ScreenMenuKey menuKey;

  @override
  ConsumerState<ScreenSessionPanel> createState() => _ScreenSessionPanelState();
}

/// The key in SharedPreferences: the names of the folded groups.
const kScreenPanelFoldedKey = 'screen_panel_folded';

/// Which groups of the session panel are folded, in this profile's
/// preferences on this device.
final screenPanelFoldedProvider =
    NotifierProvider<ScreenPanelFoldedNotifier, Set<ScreenActionGroup>>(ScreenPanelFoldedNotifier.new);

class ScreenPanelFoldedNotifier extends Notifier<Set<ScreenActionGroup>> {
  @override
  Set<ScreenActionGroup> build() {
    final names = ref.watch(sharedPreferencesProvider).getStringList(kScreenPanelFoldedKey) ?? const [];
    return {for (final g in ScreenActionGroup.values) if (names.contains(g.name)) g};
  }

  void toggle(ScreenActionGroup g) {
    state = state.contains(g) ? ({...state}..remove(g)) : {...state, g};
    unawaited(ref.read(sharedPreferencesProvider).setStringList(kScreenPanelFoldedKey, [for (final g in state) g.name]));
  }
}

class _ScreenSessionPanelState extends ConsumerState<ScreenSessionPanel> {
  Set<ScreenActionGroup> get _folded => ref.watch(screenPanelFoldedProvider);

  void _toggleFold(ScreenActionGroup g) => ref.read(screenPanelFoldedProvider.notifier).toggle(g);

  ScreenMenuState get _state => widget.state.value;

  ScreenDisplays get _displays => widget.displays?.value ?? const ScreenDisplays();

  /// The option that has the focus as the panel opens: the first one.
  late final ScreenAction? _first = () {
    for (final g in _groups) {
      if (ref.read(screenPanelFoldedProvider).contains(g)) continue;
      for (final a in _state.inGroup(g)) {
        if (!_topActions.contains(a) && !a.sendsKeys) return a;
      }
    }
    return null;
  }();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    widget.displays?.addListener(_changed);
  }

  @override
  void didUpdateWidget(ScreenSessionPanel old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_changed);
      widget.state.addListener(_changed);
    }
    if (old.displays != widget.displays) {
      old.displays?.removeListener(_changed);
      widget.displays?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    widget.displays?.removeListener(_changed);
    super.dispose();
  }

  /// The groups drawn: those with an action offered, and Displays when the
  /// remote has several, in the list's order.
  List<ScreenActionGroup> get _groups {
    final withDisplays = _displays.several && widget.onDisplay != null;
    return [
      for (final g in ScreenActionGroup.values)
        if ((g == ScreenActionGroup.displays && withDisplays) ||
            _state.inGroup(g).any((a) => !_topActions.contains(a)))
          g,
    ];
  }

  /// The session moved on. Its view hands the state on while it builds, so
  /// the panel is redrawn once that frame is done.
  void _changed() {
    if (!mounted) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _pick(ScreenAction a) {
    if (_state.enabled(a)) widget.onAction(a);
  }

  /// The two that sit at the top as buttons, not in their group.
  static const _topActions = {ScreenAction.disconnect, ScreenAction.fullScreen};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final width = screenPanelWidthFor(MediaQuery.sizeOf(context).width);
    final touch = touchSizedAt(context);
    return Material(
      key: const ValueKey('screen-panel'),
      color: ZestColors.chromeElevated,
      elevation: 12,
      child: SafeArea(
        left: false,
        right: false,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: l10n.screenPanelTitle,
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
                SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
              },
              child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(l10n),
                  _topButtons(l10n, touch),
                  Divider(height: 1, color: ZestColors.borderDefault),
                  Expanded(
                    child: ListView(
                      key: const ValueKey('screen-panel-list'),
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [for (final g in _groups) _group(l10n, g, touch)],
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppLocalizations l10n) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  l10n.screenPanelTitle,
                  style: TextStyle(color: ZestColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('screen-panel-close'),
              tooltip: l10n.close,
              onPressed: widget.onClose,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: Icon(LucideIcons.x, size: 18, color: ZestColors.textSecondary),
            ),
          ],
        ),
      );

  Widget _topButtons(AppLocalizations l10n, bool touch) {
    final buttons = [
      if (_state.offers(ScreenAction.disconnect))
        _BigButton(
          key: const ValueKey('screen-panel-disconnect'),
          icon: LucideIcons.powerOff,
          label: l10n.sessionInfoDisconnect,
          color: ZestColors.statusError,
          onTap: () => _pick(ScreenAction.disconnect),
        ),
      if (_state.offers(ScreenAction.fullScreen))
        _BigButton(
          key: const ValueKey('screen-panel-fullScreen'),
          icon: _state.isOn(ScreenAction.fullScreen) ? LucideIcons.minimize : LucideIcons.expand,
          label: _state.isOn(ScreenAction.fullScreen) ? l10n.screenExitFullScreen : l10n.screenFullScreen,
          color: ZestColors.textPrimary,
          onTap: () => _pick(ScreenAction.fullScreen),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: buttons[i]),
          ],
        ],
      ),
    );
  }

  Widget _group(AppLocalizations l10n, ScreenActionGroup g, bool touch) {
    final actions = [for (final a in _state.inGroup(g)) if (!_topActions.contains(a)) a];
    final sends = [for (final a in actions) if (a.sendsKeys) a];
    final rows = <Widget>[];
    var keysDrawn = false;
    for (final a in actions) {
      if (a.sendsKeys) {
        if (keysDrawn) continue;
        keysDrawn = true;
        rows.add(_keys(l10n, sends));
        continue;
      }
      rows.add(_OptionRow(
        key: ValueKey('screen-panel-${a.name}'),
        action: a,
        label: a.labelIn(l10n, menuKey: widget.menuKey),
        // A phone's session is the one that offers the touch modes (the size of
        // the rows says nothing of it: a computer can have large ones).
        help: _state.whyNotIn(l10n, a) ??
            screenActionHelpIn(l10n, a, phone: _state.offers(ScreenAction.touchPointer)),
        on: _state.isOn(a),
        enabled: _state.enabled(a),
        touch: touch,
        autofocus: a == _first,
        onTap: () => _pick(a),
      ));
    }
    final onDisplay = widget.onDisplay;
    if (g == ScreenActionGroup.displays && _displays.several && onDisplay != null) {
      final d = _displays;
      rows.addAll([
        for (final s in d.list)
          ScreenDisplayChoiceRow(
            key: ValueKey('screen-panel-display-${s.index}'),
            title: screenDisplayNameIn(l10n, s),
            subtitle: [screenDisplaySizeIn(l10n, s), if (s.primary) l10n.screenDisplayPrimary].join(' · '),
            spoken: screenDisplaySpokenIn(l10n, s),
            on: d.shown == s.index,
            onTap: () => onDisplay(s.index),
          ),
        ScreenDisplayChoiceRow(
          key: const ValueKey('screen-panel-display-all'),
          title: l10n.screenDisplayAll,
          subtitle: l10n.screenDisplayAllHelp,
          spoken: l10n.screenDisplayAll,
          on: d.shown == null,
          onTap: () => onDisplay(null),
        ),
      ]);
    }
    final folded = _folded.contains(g);
    final title = g.titleIn(l10n);
    return Padding(
      key: ValueKey('screen-panel-group-${g.name}'),
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The heading folds the group: a tap, or Enter on it.
          Semantics(
            header: true,
            button: true,
            expanded: !folded,
            label: title,
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('screen-panel-fold-${g.name}'),
              onTap: () => _toggleFold(g),
              autofocus: _first == null && g == _groups.firstOrNull,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: touch ? 48 : 36),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.toUpperCase(),
                          style: TextStyle(
                            color: ZestColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: folded ? -0.25 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 150),
                        child: Icon(LucideIcons.chevronDown, size: 16, color: ZestColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!folded) ...rows,
        ],
      ),
    );
  }

  /// The keys to send, as a row of buttons that wraps.
  Widget _keys(AppLocalizations l10n, List<ScreenAction> sends) => Padding(
        key: const ValueKey('screen-panel-keys'),
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in sends)
              _KeyButton(
                key: ValueKey('screen-panel-${a.name}'),
                label: a.labelIn(l10n, menuKey: widget.menuKey),
                enabled: _state.enabled(a),
                onTap: () => _pick(a),
              ),
            // Why they cannot be sent now (all of them for one reason).
            if (sends.map((a) => _state.whyNotIn(l10n, a)).nonNulls.firstOrNull case final why?)
              SizedBox(
                width: double.infinity,
                child: Text(why, style: TextStyle(color: ZestColors.textMuted, fontSize: 12)),
              ),
          ],
        ),
      );
}

/// A wide button at the top of the panel.
class _BigButton extends StatelessWidget {
  const _BigButton({super.key, required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          side: BorderSide(color: ZestColors.borderDefault),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text(label, maxLines: 2, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
}

/// A key or a chord to send.
class _KeyButton extends StatelessWidget {
  const _KeyButton({super.key, required this.label, required this.enabled, required this.onTap});

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: const Icon(LucideIcons.keyboard, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(
          foregroundColor: ZestColors.textPrimary,
          minimumSize: Size(0, touchSizedAt(context) ? 48 : 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          side: BorderSide(color: ZestColors.borderDefault),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
}

/// One option: its mark (a switch, a choice's dot, or the action's icon), its
/// words and the line that says what it does. The whole row is the target.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.action,
    required this.label,
    required this.help,
    required this.on,
    required this.enabled,
    required this.touch,
    required this.onTap,
    this.autofocus = false,
  });

  final ScreenAction action;
  final bool autofocus;
  final String label;
  final String? help;
  final bool on;
  final bool enabled;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = action.kind;
    final ink = enabled ? ZestColors.textPrimary : ZestColors.textMuted;
    final Widget mark = switch (kind) {
      // The row is the stop: its switch is drawn, not focused or read apart.
      ScreenActionKind.toggle => ExcludeFocus(
          child: ExcludeSemantics(
          child: SizedBox(
            height: 24,
            child: FittedBox(
              child: Switch(
                value: on,
                onChanged: enabled ? (_) => onTap() : null,
                activeTrackColor: AppColors.brandOrange,
              ),
            ),
          ),
        ),
        ),
      ScreenActionKind.choice => Icon(
          on ? LucideIcons.circleDot : LucideIcons.circle,
          size: 18,
          color: on ? AppColors.v3AccentInk : ZestColors.textMuted,
        ),
      ScreenActionKind.plain => Icon(action.icon, size: 18, color: ink),
    };
    // Every row's words start at one line: a switch has the action's icon
    // at the start and the switch at the end.
    final icon = Icon(action.icon, size: 18, color: ink);
    return Semantics(
      button: kind == ScreenActionKind.plain,
      toggled: kind == ScreenActionKind.toggle ? on : null,
      checked: kind == ScreenActionKind.choice ? on : null,
      inMutuallyExclusiveGroup: kind == ScreenActionKind.choice ? true : null,
      enabled: enabled,
      child: InkWell(
        onTap: enabled ? onTap : null,
        autofocus: autofocus,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 56 : 44),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
            child: Row(
              children: [
                if (kind == ScreenActionKind.toggle) icon else mark,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: TextStyle(color: ink, fontSize: 14, fontWeight: FontWeight.w500)),
                      if (help != null) ...[
                        const SizedBox(height: 2),
                        Text(help!, style: TextStyle(color: ZestColors.textMuted, fontSize: 12, height: 1.35)),
                      ],
                    ],
                  ),
                ),
                if (kind == ScreenActionKind.toggle) ...[const SizedBox(width: 12), mark],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks how a finger drives the remote pointer, each way with a line that
/// says what it does (the app's choice question). The mode picked, or null
/// when it was closed.
Future<ScreenTouchMode?> showScreenTouchModeQuestion(BuildContext context, {required ScreenTouchMode current}) {
  final l10n = AppLocalizations.of(context)!;
  return showZestChoice<ScreenTouchMode>(
    context,
    key: const ValueKey('screen-touch-question'),
    title: l10n.screenTouchQuestionTitle,
    icon: LucideIcons.hand,
    selected: current,
    choices: [
      for (final m in ScreenTouchMode.values)
        ZestChoice(
          key: ValueKey('screen-touch-question-${m.name}'),
          value: m,
          label: ScreenAction.ofTouch(m).labelIn(l10n),
          detail: screenActionHelpIn(l10n, ScreenAction.ofTouch(m)),
          icon: ScreenAction.ofTouch(m).icon,
        ),
    ],
  );
}

/// Says the touch mode picked, for a screen reader (the question closed).
void announceScreenTouchMode(BuildContext context, ScreenTouchMode m) =>
    zestAnnounce(context, ScreenAction.ofTouch(m).labelIn(AppLocalizations.of(context)!));
