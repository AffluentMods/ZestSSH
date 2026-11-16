import 'dart:convert';
import 'dart:math';

/// The secret that makes a ticket readable: 32 random bytes, base64url
/// without padding (43 characters).
///
/// The app makes it when it sends a ticket and keeps it in the encrypted
/// database; the server stores only its SHA-256. It is random per ticket:
/// not an account, not an install id, and nothing links one ticket's token
/// to another's.
class TicketToken {
  TicketToken._();

  static final RegExp _shape = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static bool isValid(String? v) => v != null && _shape.hasMatch(v);

  /// What a "see exactly what is sent" preview shows in place of the token:
  /// it is a secret, and a preview is the kind of thing that gets pasted
  /// into a chat.
  static const String preview = '<a random key, kept on this device>';
}
