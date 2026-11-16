/// Calculates the best fuzzy match score across multiple text fields.
/// Returns a score > 0 if [query] fuzzy-matches any text in [texts].
/// Higher scores indicate better matches.
double bestFuzzyScore(String query, List<String?> texts) {
  if (query.isEmpty) return 0.0;

  final lowerQuery = query.toLowerCase();
  double best = 0.0;

  for (final text in texts) {
    if (text == null || text.isEmpty) continue;
    final score = _fuzzyScore(lowerQuery, text.toLowerCase());
    if (score > best) best = score;
  }

  return best;
}

double _fuzzyScore(String query, String text) {
  // Bonus for shorter texts (more relevant match).
  final lengthBonus = 0.01 / (text.length + 1);

  // Exact substring match.
  if (text.contains(query)) {
    return 1.0 + lengthBonus;
  }

  // Prefix match.
  if (text.startsWith(query)) {
    return 0.95 + lengthBonus;
  }

  // Character-by-character fuzzy matching.
  int queryIndex = 0;
  int consecutiveCount = 0;
  int maxConsecutive = 0;
  int totalMatched = 0;
  bool lastMatched = false;

  for (int i = 0; i < text.length && queryIndex < query.length; i++) {
    if (text[i] == query[queryIndex]) {
      queryIndex++;
      totalMatched++;
      if (lastMatched) {
        consecutiveCount++;
        if (consecutiveCount > maxConsecutive) {
          maxConsecutive = consecutiveCount;
        }
      } else {
        consecutiveCount = 1;
        if (consecutiveCount > maxConsecutive) {
          maxConsecutive = consecutiveCount;
        }
      }
      lastMatched = true;
    } else {
      lastMatched = false;
    }
  }

  // All query characters must be found in order.
  if (queryIndex < query.length) return 0.0;

  // Base score from ratio of matched characters.
  final matchRatio = totalMatched / text.length;
  // Bonus for consecutive character runs.
  final consecutiveBonus = 0.2 * (maxConsecutive / query.length);

  return 0.1 + (matchRatio * 0.5) + consecutiveBonus + lengthBonus;
}
