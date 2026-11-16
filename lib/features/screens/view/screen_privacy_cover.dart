// What covers a remote screen's picture while the app is not in front on a
// phone or tablet (4.0; found in a security
// review). iOS and Android take a picture of the app as it leaves for their app
// switchers (Recents, the iOS snapshot cache), and a remote screen can show
// anything: a password manager, mail, a console. As the app stops being in
// front (inactive, hidden, paused) the picture is covered, and uncovered once
// it is back. A computer's switcher shows live windows, and its person often
// watches a screen while typing elsewhere, so a computer is left uncovered.
//
// Android also offers FLAG_SECURE, which blanks the switcher's picture for
// certain; the app does not set it (MainActivity: screenshots
// and screen sharing are to keep working), so the cover is drawn as the app
// leaves, as early as Flutter is told.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Over a remote screen's picture (in a Stack, over the picture): nothing
/// while the app is in front, a plain cover while it is not, on a phone or
/// tablet.
class ScreenPrivacyCover extends StatefulWidget {
  const ScreenPrivacyCover({super.key});

  /// Whether this device is a phone or tablet (tests set it).
  @visibleForTesting
  static bool? debugMobile;

  static bool get _mobile => debugMobile ?? (!kIsWeb && (Platform.isIOS || Platform.isAndroid));

  /// Whether the picture is covered with the app in [state].
  static bool coversIn(AppLifecycleState? state) =>
      _mobile && state != null && state != AppLifecycleState.resumed && state != AppLifecycleState.detached;

  @override
  State<ScreenPrivacyCover> createState() => _ScreenPrivacyCoverState();
}

class _ScreenPrivacyCoverState extends State<ScreenPrivacyCover> {
  late final AppLifecycleListener _life;
  late bool _covered;

  @override
  void initState() {
    super.initState();
    _covered = ScreenPrivacyCover.coversIn(WidgetsBinding.instance.lifecycleState);
    _life = AppLifecycleListener(onStateChange: (state) {
      final covered = ScreenPrivacyCover.coversIn(state);
      if (covered != _covered && mounted) setState(() => _covered = covered);
    });
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: !_covered
          ? const SizedBox.shrink()
          : const ColoredBox(
              key: ValueKey('screen-privacy-cover'),
              color: AppColors.screenLetterbox,
              child: Center(child: Icon(LucideIcons.eyeOff, size: 36, color: AppColors.screenLetterboxInk)),
            ),
    );
  }
}
