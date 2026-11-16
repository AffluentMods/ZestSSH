import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// How long a secret copied to the clipboard stays there.
const kSecretClipboardLife = Duration(seconds: 45);

/// How long a team's invite code or its link stays there. It is pasted into
/// a chat or an email to the person invited, which takes longer than a paste
/// into a field of this device.
const kInviteClipboardLife = Duration(minutes: 3);

/// [said] ("Copied", "Code copied") with, on a line of its own, that the
/// clipboard clears by itself: what a screen says after [SecretClipboard.copy]
/// where its own words do not say so. [note] says when, where that is not
/// after [kSecretClipboardLife].
String clearsSoon(AppLocalizations l10n, String said, {String? note}) =>
    '$said\n${note ?? l10n.identityEditClipboardAutoClearNote}';

/// A secret copied to the clipboard (a private key, an API key, a recovery
/// key, two-step codes) is taken off it [kSecretClipboardLife]
/// later, whatever screen it was copied from, and when the app locks; only
/// where the clipboard still holds it, so what the person copied since stays.
///
/// Each screen kept its own timer and cancelled it when it closed (found 16
/// October 2026 in the client's security review): a secret copied, pasted and
/// the screen closed within 45 seconds, the usual way, stayed on the
/// clipboard for good, though the screen said it would be cleared; locking
/// cleared only the app's own clipboard history.
class SecretClipboard {
  SecretClipboard._();

  static Timer? _timer;
  static String? _held;

  /// Copies [secret], to be taken off the clipboard after [life].
  static Future<void> copy(String secret, {Duration life = kSecretClipboardLife}) async {
    await Clipboard.setData(ClipboardData(text: secret));
    _timer?.cancel();
    _held = secret;
    _timer = Timer(life, () => unawaited(clear()));
  }

  /// Takes the secret copied last off the clipboard now, where it is still
  /// what the clipboard holds.
  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    final held = _held;
    _held = null;
    if (held == null) return;
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == held) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // A clipboard that cannot be read is left as it is.
    }
  }

  /// Whether a secret copied is waiting to be taken off (tests).
  static bool get holding => _held != null;
}
