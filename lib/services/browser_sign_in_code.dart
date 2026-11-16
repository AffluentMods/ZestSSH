import 'dart:convert';

import 'package:crypto/crypto.dart' as c;

/// Crockford's base32: no I, L, O or U.
const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// What is hashed before the challenge, so the code is good for nothing else.
const _label = 'zestssh.sign-in-code.v1\n';

/// The code a computer's browser sign-in shows
/// for [challenge] exactly as the link carries it: the first
/// 30 bits of SHA-256 of UTF-8("zestssh.sign-in-code.v1\n" + challenge), as
/// six characters of Crockford's base32, such as "K7P2QX".
///
/// The app listens on 127.0.0.1 for the sign-in it started, and every person
/// signed in to the computer shares those ports: another one could start a
/// sign-in of their own, with their own challenge, and get this person to
/// open it, and the sign-in would reach their program. So the app shows the
/// code of the challenge in the link it opened, and zestssh.com asks for it
/// before anything is signed in: only the app that started a sign-in shows
/// its code. The same function is on the website (src/lib/signInCode.js),
/// with the same test vectors (test/services/browser_sign_in_code_test.dart).
String browserSignInCode(String challenge) {
  final d = c.sha256.convert(utf8.encode('$_label$challenge')).bytes;
  final bits = (d[0] << 22) | (d[1] << 14) | (d[2] << 6) | (d[3] >> 2);
  final code = StringBuffer();
  for (var shift = 25; shift >= 0; shift -= 5) {
    code.write(_alphabet[(bits >> shift) & 31]);
  }
  return code.toString();
}

/// [code] as the app shows it: two groups of three ("K7P 2QX").
String groupBrowserSignInCode(String code) => '${code.substring(0, 3)} ${code.substring(3)}';
