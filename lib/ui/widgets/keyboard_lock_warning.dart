import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// A one-line advisory shown beneath a password field when Caps Lock is active
/// - the classic "why is my password wrong?" gotcha. Renders nothing at all
/// when Caps Lock is off (the "only when enabled" rule), and updates live as
/// the user toggles the key.
///
/// Caps Lock only: Num Lock is normally *on*, so warning about it would fire on
/// nearly every password field - noise, not help. Physical-keyboard only: soft
/// keyboards report no persistent lock modes, so this stays invisible on
/// phones/tablets, which is the intended behaviour.
class KeyboardLockWarning extends StatefulWidget {
  const KeyboardLockWarning({super.key});

  @override
  State<KeyboardLockWarning> createState() => _KeyboardLockWarningState();
}

class _KeyboardLockWarningState extends State<KeyboardLockWarning> {
  bool _capsOn = false;

  @override
  void initState() {
    super.initState();
    _sync();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// A passive observer - never consumes the event (returns false); it only
  /// re-reads the lock state after each key so the advisory tracks live toggles.
  bool _onKey(KeyEvent event) {
    _sync();
    return false;
  }

  void _sync() {
    final capsOn = HardwareKeyboard.instance.lockModesEnabled
        .contains(KeyboardLockMode.capsLock);
    if (capsOn != _capsOn) {
      if (mounted) {
        setState(() => _capsOn = capsOn);
      } else {
        _capsOn = capsOn;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_capsOn) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final message = l10n == null
        ? 'Caps Lock enabled'
        : l10n.keyboardLockEnabled(l10n.keyboardCapsLock);
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              LucideIcons.alertTriangle,
              size: 13,
              color: AppColors.v3Warning,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12,
                color: AppColors.v3Warning,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
