import 'package:flutter/painting.dart';

/// [phrase] (a whole phrase in the person's language, "3 sessions" or
/// "세션 3개") as spans, with the first [digits] in it drawn in [number]: a
/// number styled apart from its words without gluing the words on in code,
/// which fixed their order. Where the phrase does
/// not hold [digits] it is one span.
TextSpan numberInPhrase(String phrase, String digits, {required TextStyle number}) {
  final at = digits.isEmpty ? -1 : phrase.indexOf(digits);
  if (at < 0) return TextSpan(text: phrase);
  final end = at + digits.length;
  return TextSpan(children: [
    if (at > 0) TextSpan(text: phrase.substring(0, at)),
    TextSpan(text: digits, style: number),
    if (end < phrase.length) TextSpan(text: phrase.substring(end)),
  ]);
}
