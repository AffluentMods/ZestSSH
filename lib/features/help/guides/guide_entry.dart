/// The feature guides of Help > Guides (3.0): one Markdown page per feature
/// on the docs site, written once and shown everywhere. The app carries only
/// a small index of them ([GuideEntry], compiled in from the guides'
/// frontmatter by tool/guides_index.dart) and fetches a guide's words from
/// [kGuidesOrigin] when it is opened.
library;

import 'package:zestssh/config/official_identity.dart';

/// The one place guides, and their pictures, come from. Nothing else is
/// fetched by the guide reader.
String get kGuidesOrigin => kZestDocsOrigin;

/// What a guide's address may be called: lower case words and dashes.
final RegExp kGuideSlug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// One guide, as the index knows it.
class GuideEntry {
  const GuideEntry({
    required this.slug,
    required this.title,
    required this.summary,
    required this.keywords,
    required this.platforms,
    required this.features,
    required this.appliesTo,
  });

  /// Its address on the docs site: `/guides/<slug>/`.
  final String slug;

  /// Its title, in English, as the docs site has it.
  final String title;

  /// One line: what the guide gets you.
  final String summary;

  /// The words people search with, synonyms included, lower case.
  final List<String> keywords;

  /// Where its steps apply: desktop, phone, tablet.
  final List<String> platforms;

  /// The app's feature ids whose "?" opens it.
  final List<String> features;

  /// The app version its steps were checked against.
  final String appliesTo;

  /// The guide's raw Markdown, which the reader fetches.
  Uri get markdownUri => guideMarkdownUri(slug);

  /// The guide as a web page.
  Uri get pageUri => guidePageUri(slug);
}

/// The raw Markdown of the guide at [slug]: `/guides/<slug>.md`.
Uri guideMarkdownUri(String slug) {
  if (!kGuideSlug.hasMatch(slug)) throw ArgumentError.value(slug, 'slug', 'not a guide');
  return Uri.parse('$kGuidesOrigin/guides/$slug.md');
}

/// The web page of the guide at [slug]: `/guides/<slug>/`.
Uri guidePageUri(String slug) {
  if (!kGuideSlug.hasMatch(slug)) throw ArgumentError.value(slug, 'slug', 'not a guide');
  return Uri.parse('$kGuidesOrigin/guides/$slug/');
}
