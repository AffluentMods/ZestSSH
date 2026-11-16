/// A translated sentence with one value in it, split around that value so the
/// value can be drawn apart (in bold, in a pill) while the words around it
/// stay where the language put them. [sentence] is the sentence made with
/// [marker] for the value; the answer is what stands before the value and
/// what stands after it. Without the marker in it (a translation that left
/// the value out), the whole sentence is before and nothing after.
///
/// Sentences were glued from a translated prefix and the value ("You own " +
/// name), so no language could put the name anywhere but
/// last.
(String before, String after) aroundValue(String sentence, {String marker = aroundValueMarker}) {
  final at = sentence.indexOf(marker);
  if (at < 0) return (sentence, '');
  return (sentence.substring(0, at), sentence.substring(at + marker.length));
}

/// What a sentence is made with in place of its value, for [aroundValue].
const aroundValueMarker = '\u0001';
