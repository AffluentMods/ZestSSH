import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// How strong a [haptic] is.
enum Haptic { light, medium, heavy, selection }

/// The app's haptic feedback, given only while its person leaves it on
/// (Settings > Haptic feedback, which nothing read: every tap buzzed with it
/// off). Every buzz of the app goes through here; a terminal's bell is not
/// one of them, it has a switch of its own.
void haptic(WidgetRef ref, Haptic kind) {
  if (!ref.read(hapticFeedbackProvider)) return;
  _buzz(kind);
}

/// [haptic] for a widget with no WidgetRef (a switch): the same setting,
/// read through [context]'s ProviderScope; none (a bare widget), or one whose
/// settings cannot be read (no preferences behind it), buzzes nothing: the
/// buzz never stops the tap it goes with (a switch threw and did not turn).
void hapticIn(BuildContext context, Haptic kind) {
  final bool on;
  try {
    on = ProviderScope.containerOf(context, listen: false).read(hapticFeedbackProvider);
  } catch (_) {
    return;
  }
  if (on) _buzz(kind);
}

void _buzz(Haptic kind) {
  switch (kind) {
    case Haptic.light:
      HapticFeedback.lightImpact();
    case Haptic.medium:
      HapticFeedback.mediumImpact();
    case Haptic.heavy:
      HapticFeedback.heavyImpact();
    case Haptic.selection:
      HapticFeedback.selectionClick();
  }
}
