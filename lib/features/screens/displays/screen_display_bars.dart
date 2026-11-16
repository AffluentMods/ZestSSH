// Remote screens (4.0): choosing which of a remote's displays is shown.
// On a computer, a segment in the top bar ("1  2  3  All") and a strip down the
// left with a small live picture of each display; on a phone, a button in the
// bar ("2 of 3") that opens a list. Each follows the session's displays as they
// change (one added or dropped mid-session, the one shown changed by a key or
// by three fingers) and hands a pick to [onDisplay] (null: all displays). With
// one display there is nothing to choose, and nothing is drawn.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/zest_dialog.dart' show ZestChoice, showZestChoice;

import 'package:zestssh/features/screens/model/screen_displays.dart';

export 'package:zestssh/features/screens/model/screen_displays.dart';

/// The words a display goes by: "Display 2".
String screenDisplayNameIn(AppLocalizations l10n, ScreenDisplay d) => l10n.screenDisplayName(d.index + 1);

/// Its size as written: "2560 × 1440".
String screenDisplaySizeIn(AppLocalizations l10n, ScreenDisplay d) => l10n.screenDisplaySize(d.width, d.height);

/// What a screen reader says for it: "Display 2, 2560 by 1440, main".
String screenDisplaySpokenIn(AppLocalizations l10n, ScreenDisplay d) => [
      screenDisplayNameIn(l10n, d),
      l10n.screenDisplaySizeSpoken(d.width, d.height),
      if (d.primary) l10n.screenDisplayPrimary,
    ].join(', ');

/// Rebuilds [builder] with the displays as they change.
class _Follow extends StatelessWidget {
  const _Follow({required this.displays, required this.builder});

  final ValueListenable<ScreenDisplays> displays;
  final Widget Function(BuildContext context, ScreenDisplays d) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ScreenDisplays>(
        valueListenable: displays,
        builder: (context, d, _) => d.several ? builder(context, d) : const SizedBox.shrink(),
      );
}

// A computer's top bar.

/// "1  2  3  All" in the top bar, the one shown filled.
class ScreenDisplaySegment extends StatelessWidget {
  const ScreenDisplaySegment({super.key, required this.displays, required this.onDisplay});

  final ValueListenable<ScreenDisplays> displays;
  final ValueChanged<int?> onDisplay;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final touch = touchSizedAt(context);
    final height = touch ? 40.0 : 24.0;
    return _Follow(
      displays: displays,
      builder: (context, d) {
        Widget item(String id, String text, String tip, String spoken, int? index) {
          final on = d.shown == index;
          return Tooltip(
            message: tip,
            child: Semantics(
              button: true,
              selected: on,
              inMutuallyExclusiveGroup: true,
              label: spoken,
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('screen-display-segment-$id'),
                borderRadius: BorderRadius.circular(5),
                onTap: () => onDisplay(index),
                child: Container(
                  constraints: BoxConstraints(minWidth: touch ? 48 : 28, minHeight: height),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AppColors.brandOrange.withValues(alpha: 0.18) : null,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? AppColors.v3AccentInk : ZestColors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Container(
          key: const ValueKey('screen-display-segment'),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            border: Border.all(color: ZestColors.borderDefault),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in d.list)
                item(
                  '${s.index}',
                  '${s.index + 1}',
                  '${screenDisplayNameIn(l10n, s)} (${screenDisplaySizeIn(l10n, s)})',
                  screenDisplaySpokenIn(l10n, s),
                  s.index,
                ),
              item('all', l10n.screenDisplayAllShort, l10n.screenDisplayAll, l10n.screenDisplayAll, null),
            ],
          ),
        );
      },
    );
  }
}

// A computer's strip down the left.

/// The strip's width, open.
const kScreenDisplayStripWidth = 168.0;

/// A small live picture of each display down the left, the one shown outlined;
/// it can be closed to a thin rail and opened again ([open], [onOpenChanged]).
/// [preview] draws a display's picture at the size asked.
class ScreenDisplayStrip extends StatelessWidget {
  const ScreenDisplayStrip({
    super.key,
    required this.displays,
    required this.onDisplay,
    required this.preview,
    required this.open,
    required this.onOpenChanged,
  });

  final ValueListenable<ScreenDisplays> displays;
  final ValueChanged<int?> onDisplay;
  final Widget Function(int index, Size size) preview;
  final bool open;
  final ValueChanged<bool> onOpenChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final touch = touchSizedAt(context);
    final button = touch ? 48.0 : 28.0;
    return _Follow(
      displays: displays,
      builder: (context, d) {
        if (!open) {
          return Container(
            key: const ValueKey('screen-display-strip-closed'),
            width: button + 4,
            alignment: Alignment.topCenter,
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: ZestColors.surfacePanel,
              border: BorderDirectional(end: BorderSide(color: ZestColors.borderDefault)),
            ),
            child: IconButton(
              key: const ValueKey('screen-display-strip-open'),
              tooltip: l10n.screenDisplaysShow,
              constraints: BoxConstraints.tightFor(width: button, height: button),
              padding: EdgeInsets.zero,
              onPressed: () => onOpenChanged(true),
              icon: Icon(LucideIcons.panelLeftOpen, size: 16, color: ZestColors.textSecondary),
            ),
          );
        }
        const inner = kScreenDisplayStripWidth - 24;
        return Container(
          key: const ValueKey('screen-display-strip'),
          width: kScreenDisplayStripWidth,
          decoration: BoxDecoration(
            color: ZestColors.surfacePanel,
            border: BorderDirectional(end: BorderSide(color: ZestColors.borderDefault)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 2, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.screenGroupDisplays.toUpperCase(),
                          style: TextStyle(
                            color: ZestColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('screen-display-strip-close'),
                      tooltip: l10n.screenDisplaysHide,
                      constraints: BoxConstraints.tightFor(width: button, height: button),
                      padding: EdgeInsets.zero,
                      onPressed: () => onOpenChanged(false),
                      icon: Icon(LucideIcons.panelLeftClose, size: 16, color: ZestColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  children: [
                    for (final s in d.list)
                      _StripTile(
                        key: ValueKey('screen-display-strip-${s.index}'),
                        display: s,
                        on: d.shown == s.index,
                        width: inner,
                        preview: preview,
                        onTap: () => onDisplay(s.index),
                      ),
                    _AllTile(
                      key: const ValueKey('screen-display-strip-all'),
                      on: d.shown == null,
                      touch: touch,
                      onTap: () => onDisplay(null),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StripTile extends StatelessWidget {
  const _StripTile({
    super.key,
    required this.display,
    required this.on,
    required this.width,
    required this.preview,
    required this.onTap,
  });

  final ScreenDisplay display;
  final bool on;
  final double width;
  final Widget Function(int index, Size size) preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final d = display;
    // The remote's own shape, kept between a flat and a tall display's.
    final ratio = d.width > 0 && d.height > 0 ? (d.width / d.height).clamp(0.5, 4.0) : 16 / 9;
    final size = Size(width - 4, ((width - 4) / ratio).roundToDouble());
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        label: screenDisplaySpokenIn(l10n, d),
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: on ? AppColors.brandOrange : ZestColors.borderDefault,
                    width: on ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox.fromSize(
                    size: size,
                    child: ColoredBox(color: AppColors.screenLetterbox, child: preview(d.index, size)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    screenDisplayNameIn(l10n, d),
                    style: TextStyle(
                      color: on ? ZestColors.textPrimary : ZestColors.textSecondary,
                      fontSize: 12,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (d.primary) ...[
                    const SizedBox(width: 6),
                    Icon(LucideIcons.star, size: 11, color: ZestColors.textMuted),
                  ],
                ],
              ),
              Text(
                screenDisplaySizeIn(l10n, d),
                style: TextStyle(
                  color: ZestColors.textMuted,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllTile extends StatelessWidget {
  const _AllTile({super.key, required this.on, required this.touch, required this.onTap});

  final bool on;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      selected: on,
      inMutuallyExclusiveGroup: true,
      label: l10n.screenDisplayAll,
      excludeSemantics: true,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(LucideIcons.layoutGrid, size: 14, color: on ? AppColors.v3AccentInk : ZestColors.textSecondary),
        label: Text(l10n.screenDisplayAll, style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          foregroundColor: on ? AppColors.v3AccentInk : ZestColors.textSecondary,
          minimumSize: Size(0, touch ? 48 : 32),
          side: BorderSide(
            color: on ? AppColors.brandOrange : ZestColors.borderDefault,
            width: on ? 2 : 1,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

// A phone.

/// The bar's button: "2 of 3" (or "All"), opening the list.
class ScreenDisplayButton extends StatelessWidget {
  const ScreenDisplayButton({super.key, required this.displays, required this.onDisplay, this.ink});

  final ValueListenable<ScreenDisplays> displays;
  final ValueChanged<int?> onDisplay;

  /// The words' color over the phone's dark bar.
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _Follow(
      displays: displays,
      builder: (context, d) {
        final shown = d.shown;
        final text = shown == null ? l10n.screenDisplayAllShort : l10n.screenDisplayOf(shown + 1, d.list.length);
        return Semantics(
          button: true,
          label: '${l10n.screenDisplayChoose}, ${shown == null ? l10n.screenDisplayAll : l10n.screenDisplayOf(shown + 1, d.list.length)}',
          excludeSemantics: true,
          child: Tooltip(
            message: l10n.screenDisplayChoose,
            child: InkWell(
              key: const ValueKey('screen-display-button'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => showScreenDisplayPicker(context, displays: displays, onDisplay: onDisplay),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.monitor, size: 17, color: ink ?? ZestColors.textPrimary),
                      const SizedBox(width: 6),
                      Text(
                        text,
                        style: TextStyle(
                          color: ink ?? ZestColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The list of displays, each with its size, and All displays last, in the
/// app's choice question (a phone's sheet); a pick closes it. Under the title,
/// the three finger swipe that does the same from the picture.
Future<void> showScreenDisplayPicker(
  BuildContext context, {
  required ValueListenable<ScreenDisplays> displays,
  required ValueChanged<int?> onDisplay,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final d = displays.value;
  // -1 stands for All displays (a choice's value cannot be null: null is "closed").
  final picked = await showZestChoice<int>(
    context,
    key: const ValueKey('screen-display-picker'),
    title: l10n.screenGroupDisplays,
    subtitle: l10n.screenDisplaySwipeHint,
    icon: LucideIcons.monitor,
    selected: d.shown ?? -1,
    choices: [
      for (final s in d.list)
        ZestChoice(
          key: ValueKey('screen-display-picker-${s.index}'),
          value: s.index,
          label: screenDisplayNameIn(l10n, s),
          detail: [screenDisplaySizeIn(l10n, s), if (s.primary) l10n.screenDisplayPrimary].join(' · '),
        ),
      ZestChoice(
        key: const ValueKey('screen-display-picker-all'),
        value: -1,
        label: l10n.screenDisplayAll,
        detail: l10n.screenDisplayAllHelp,
      ),
    ],
  );
  if (picked == null) return;
  onDisplay(picked < 0 ? null : picked);
}

/// One display to choose, as the picker and the session panel draw it: a dot,
/// its name and its size.
class ScreenDisplayChoiceRow extends StatelessWidget {
  const ScreenDisplayChoiceRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.spoken,
    required this.on,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String spoken;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        checked: on,
        inMutuallyExclusiveGroup: true,
        label: spoken,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 56 : 44),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(
                    on ? LucideIcons.circleDot : LucideIcons.circle,
                    size: 18,
                    color: on ? AppColors.v3AccentInk : ZestColors.textMuted,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title,
                            style: TextStyle(color: ZestColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 2),
                        Text(subtitle, style: TextStyle(color: ZestColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
