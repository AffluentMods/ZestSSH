import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/features/help/guides/guides_index.g.dart';

/// Search over the guides index: "network" finds Networks and jump hosts,
/// "bastion" finds it too (a keyword of its), "upload files" finds SFTP.
///
/// Every word typed must be found in a guide (its title, its keywords and
/// synonyms, or its summary) for the guide to be a result; a word matches
/// another as a whole word, as its plural or singular, or as the start of
/// one (so "net" finds network while it is being typed). Results come best
/// first: a title or a whole keyword weighs most, the summary least. The
/// guides are English, so the words are compared as English letters and
/// digits; an empty query lists every guide in its order.
List<GuideEntry> searchGuides(String query, {List<GuideEntry> index = kGuidesIndex}) {
  final words = _words(query);
  if (words.isEmpty) return List.of(index);
  final phrase = words.join(' ');
  final scored = <(GuideEntry, int, int)>[];
  for (var i = 0; i < index.length; i++) {
    final g = index[i];
    final title = _words(g.title);
    final keywords = [for (final k in g.keywords) _words(k)];
    final keywordWords = [for (final k in keywords) ...k];
    final summary = _words(g.summary);
    var score = 0;
    var all = true;
    for (final w in words) {
      final s = _best(w, title, 10, 6) + _best(w, keywordWords, 8, 4) + _best(w, summary, 3, 1);
      if (s == 0) {
        all = false;
        break;
      }
      score += s;
    }
    if (!all) continue;
    // The whole query as a keyword or in the title ("jump host", "api key").
    if (keywords.any((k) => k.join(' ') == phrase)) score += 12;
    if (title.join(' ').contains(phrase)) score += 8;
    scored.add((g, score, i));
  }
  scored.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
  return [for (final s in scored) s.$1];
}

/// The guide whose "?" a page with [feature] shows, or null when none has it.
GuideEntry? guideForFeature(String feature, {List<GuideEntry> index = kGuidesIndex}) {
  for (final g in index) {
    if (g.features.contains(feature)) return g;
  }
  return null;
}

/// The guide at [slug], or null when the index has none.
GuideEntry? guideBySlug(String slug, {List<GuideEntry> index = kGuidesIndex}) {
  for (final g in index) {
    if (g.slug == slug) return g;
  }
  return null;
}

/// [whole] when [word] is one of [among] (or its plural or singular),
/// [prefix] when it starts one, else 0.
int _best(String word, List<String> among, int whole, int prefix) {
  final stem = _stem(word);
  var best = 0;
  for (final a in among) {
    if (a == word || _stem(a) == stem) return whole;
    if (best == 0 && word.length >= 2 && a.startsWith(word)) best = prefix;
  }
  return best;
}

/// One plural ending taken off: "networks" and "network" are one word,
/// "keys" and "key", "aliases" and "alias".
String _stem(String w) {
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.length > 4 && (w.endsWith('ses') || w.endsWith('xes') || w.endsWith('ches') || w.endsWith('shes'))) {
    return w.substring(0, w.length - 2);
  }
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}

/// [text] as lower-case words of letters and digits: "Wi-Fi" is "wi fi",
/// "authorized_keys" is "authorized keys". Accents are taken off the few
/// Latin letters a person may type them on.
List<String> _words(String text) {
  final folded = text.toLowerCase().replaceAllMapped(RegExp('[àáâãäåèéêëìíîïòóôõöùúûüçñ]'), (m) => _plain[m[0]!]!);
  return folded.split(RegExp('[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
}

const _plain = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', //
  'ç': 'c', 'ñ': 'n',
};
