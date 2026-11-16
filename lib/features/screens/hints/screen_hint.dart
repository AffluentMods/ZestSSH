// Remote screens (4.0): a one-time hint over the picture. The
// first time a thing can be done that nobody would guess (three fingers to
// change display, a hold for a right click, the key that lets go of the
// keyboard), one short line says it, over the top of the picture, and goes
// by itself after a while, on Got it, or as the person does what it says.
// Each hint is shown once on this device (kept through Reset all settings,
// as the app's other shown-once notes are).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart' show sharedPreferencesProvider;
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;

/// The hints, each shown once on this device.
enum ScreenHintKind {
  /// A phone with a remote of several displays: three fingers sideways.
  threeFingers,

  /// A phone in Touch mode: hold for a right click.
  holdForRightClick,

  /// A computer: the key that lets go of the keyboard and opens the panel.
  releaseKey,
}

/// The key in SharedPreferences: the names of the hints already shown, on this device.
const kScreenHintsSeenKey = 'screen_hints_seen';

/// Which hints were shown on this device; [seen] marks one.
final screenHintsSeenProvider = NotifierProvider<ScreenHintsSeenNotifier, Set<ScreenHintKind>>(ScreenHintsSeenNotifier.new);

class ScreenHintsSeenNotifier extends Notifier<Set<ScreenHintKind>> {
  @override
  Set<ScreenHintKind> build() {
    final names = ref.watch(sharedPreferencesProvider).getStringList(kScreenHintsSeenKey) ?? const [];
    return {for (final k in ScreenHintKind.values) if (names.contains(k.name)) k};
  }

  void seen(ScreenHintKind kind) {
    if (state.contains(kind)) return;
    state = {...state, kind};
    unawaited(ref.read(sharedPreferencesProvider).setStringList(kScreenHintsSeenKey, [for (final k in state) k.name]));
  }
}

/// A hint's words. [menuKey]: the name of the key that opens the panel.
String screenHintTextIn(AppLocalizations l10n, ScreenHintKind kind, {String menuKey = 'F8'}) => switch (kind) {
      ScreenHintKind.threeFingers => l10n.screenDisplaySwipeHint,
      ScreenHintKind.holdForRightClick => l10n.screenHintHoldRightClick,
      ScreenHintKind.releaseKey => l10n.screenHintReleaseKey(menuKey),
    };

IconData _iconOf(ScreenHintKind kind) => switch (kind) {
      ScreenHintKind.threeFingers => LucideIcons.hand,
      ScreenHintKind.holdForRightClick => LucideIcons.pointer,
      ScreenHintKind.releaseKey => LucideIcons.keyboard,
    };

/// Over the picture, at its top centre: the first of [offer] not yet seen on
/// this device, once. Nothing when all were seen. [done] marks one seen from
/// outside (the person did what it says), which takes it away.
class ScreenHintOverlay extends ConsumerStatefulWidget {
  const ScreenHintOverlay({super.key, required this.offer, this.menuKey = 'F8', this.stays = defaultStays});

  /// The hints that apply now, in the order to show them.
  final List<ScreenHintKind> offer;
  final String menuKey;

  /// How long one stays unless dismissed.
  final Duration stays;

  static const defaultStays = Duration(seconds: 8);

  @override
  ConsumerState<ScreenHintOverlay> createState() => _ScreenHintOverlayState();
}

class _ScreenHintOverlayState extends ConsumerState<ScreenHintOverlay> {
  ScreenHintKind? _shown;
  Timer? _goes;

  @override
  void dispose() {
    _goes?.cancel();
    super.dispose();
  }

  void _dismiss() {
    final k = _shown;
    _goes?.cancel();
    _goes = null;
    if (k != null) ref.read(screenHintsSeenProvider.notifier).seen(k);
  }

  @override
  Widget build(BuildContext context) {
    final seen = ref.watch(screenHintsSeenProvider);
    final next = widget.offer.where((k) => !seen.contains(k)).firstOrNull;
    if (next != _shown) {
      _shown = next;
      _goes?.cancel();
      _goes = null;
      if (next != null) {
        _goes = Timer(widget.stays, _dismiss);
        final l10n = AppLocalizations.of(context)!;
        final text = screenHintTextIn(l10n, next, menuKey: widget.menuKey);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) zestAnnounce(context, text);
        });
      }
    }
    final k = _shown;
    if (k == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final touch = touchSizedAt(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: ExcludeFocus(
          child: Material(
            key: ValueKey('screen-hint-${k.name}'),
            color: ZestColors.chromeElevated.withValues(alpha: 0.94),
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: ZestColors.borderDefault),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 4, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconOf(k), size: 16, color: ZestColors.textSecondary),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        screenHintTextIn(l10n, k, menuKey: widget.menuKey),
                        style: TextStyle(color: ZestColors.textPrimary, fontSize: 13, height: 1.3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      key: const ValueKey('screen-hint-got-it'),
                      onPressed: _dismiss,
                      style: TextButton.styleFrom(
                        foregroundColor: ZestColors.textPrimary,
                        minimumSize: Size(touch ? 48 : 32, touch ? 48 : 32),
                      ),
                      child: Text(l10n.screenHintGotIt),
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
}
