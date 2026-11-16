/// The guides' Markdown, read into blocks the reader draws natively (3.0,
/// Help > Guides).
///
/// The guides are written in a small part of Markdown (headings, paragraphs,
/// numbered and bulleted lists, bold, inline code, code blocks, links and
/// pictures), and that is all this reads. Nothing in a guide is ever run or
/// drawn as a web page: HTML is not read as HTML, so a `<script>` or an
/// `<img>` written in a guide shows as the text it is. Where a picture comes
/// from and where a link goes is decided by [resolveGuideImage] and
/// [resolveGuideLink], not by the page.
library;

import 'package:zestssh/features/help/guides/guide_entry.dart';

/// A run of text with one look.
class GuideSpan {
  const GuideSpan(this.text, {this.bold = false, this.italic = false, this.code = false, this.href});

  final String text;
  final bool bold;
  final bool italic;

  /// Inline code: drawn in the terminal font.
  final bool code;

  /// The link's address as the guide wrote it (see [resolveGuideLink]).
  final String? href;

  /// The run with its marks first, for tests: `[b]Save`, `[a(/x)]here`.
  @override
  String toString() {
    final marks = [if (bold) 'b', if (italic) 'i', if (code) 'c', if (href != null) 'a($href)'];
    return marks.isEmpty ? text : '[${marks.join(',')}]$text';
  }
}

/// One block of a guide.
sealed class GuideBlock {
  const GuideBlock();
}

class GuideHeading extends GuideBlock {
  const GuideHeading(this.level, this.spans);
  final int level;
  final List<GuideSpan> spans;
  String get text => spans.map((s) => s.text).join();
}

class GuideParagraph extends GuideBlock {
  const GuideParagraph(this.spans);
  final List<GuideSpan> spans;
  String get text => spans.map((s) => s.text).join();
}

/// A list; each item is blocks of its own (a step's words, then perhaps its
/// picture).
class GuideList extends GuideBlock {
  const GuideList({required this.ordered, required this.start, required this.items});
  final bool ordered;
  final int start;
  final List<List<GuideBlock>> items;
}

class GuideCode extends GuideBlock {
  const GuideCode(this.code, {this.language});
  final String code;
  final String? language;
}

/// A picture on a line of its own. [alt] names the step it shows.
class GuideImage extends GuideBlock {
  const GuideImage({required this.alt, required this.src});
  final String alt;
  final String src;
}

/// A quote, or a note set apart (`:::note` in the docs' own Markdown).
class GuideCallout extends GuideBlock {
  const GuideCallout(this.children, {this.kind, this.title});
  final List<GuideBlock> children;

  /// note, tip, caution or danger for a note; null for a quote.
  final String? kind;
  final String? title;
}

class GuideRule extends GuideBlock {
  const GuideRule();
}

/// A table: its head and its rows, each a list of cells.
class GuideTable extends GuideBlock {
  const GuideTable(this.head, this.rows);
  final List<List<GuideSpan>> head;
  final List<List<List<GuideSpan>>> rows;
}

/// The page without its frontmatter (the `---` block the docs site reads).
String stripFrontmatter(String markdown) {
  final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final body = text.startsWith('﻿') ? text.substring(1) : text;
  if (!body.startsWith('---\n')) return body;
  final end = body.indexOf('\n---', 4);
  if (end < 0) return body;
  final after = body.indexOf('\n', end + 4);
  return after < 0 ? '' : body.substring(after + 1);
}

/// The guide's title from its frontmatter, or null.
String? frontmatterTitle(String markdown) {
  final text = markdown.replaceAll('\r\n', '\n');
  if (!text.startsWith('---\n')) return null;
  final end = text.indexOf('\n---', 4);
  if (end < 0) return null;
  for (final line in text.substring(4, end).split('\n')) {
    if (line.startsWith('title:')) {
      var v = line.substring(6).trim();
      if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
        v = v.substring(1, v.length - 1);
      }
      return v.isEmpty ? null : v;
    }
  }
  return null;
}

/// [markdown] (frontmatter and all) as blocks.
List<GuideBlock> parseGuideMarkdown(String markdown) {
  final lines = stripFrontmatter(markdown).replaceAll('\t', '    ').split('\n');
  return _blocks(lines, 0);
}

// ── Blocks ────────────────────────────────────────────────────────────────

final _fence = RegExp(r'^(`{3,}|~{3,})\s*([A-Za-z0-9_+.-]*)');
final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _rule = RegExp(r'^([-*_])(\s*\1){2,}\s*$');
final _aside = RegExp(r'^:::\s*([A-Za-z]+)(?:\[(.*)\])?\s*$');
final _item = RegExp(r'^( {0,3})([-*+]|\d{1,9}[.)])( +)(.*)$');
final _tableSep = RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
final _imageLine = RegExp(r'''^!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)$''');

// A guide is a few hundred lines; a page that nests deeper than this is no
// guide, and is read flat from there.
const _maxDepth = 8;

int _indentOf(String line) => line.length - line.trimLeft().length;

bool _startsBlock(String line) {
  final t = line.trimLeft();
  if (_indentOf(line) > 3) return false;
  return _fence.hasMatch(t) ||
      _heading.hasMatch(t) ||
      _rule.hasMatch(t) ||
      _aside.hasMatch(t) ||
      t.startsWith('>') ||
      _item.hasMatch(line) ||
      _imageLine.hasMatch(t);
}

/// The cells of a table's row: `| a | b |` is a and b. A `|` in code or
/// escaped is the cell's own.
List<String> _cells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith(r'\|')) r = r.substring(0, r.length - 1);
  final cells = <String>[];
  final cell = StringBuffer();
  var code = false;
  for (var i = 0; i < r.length; i++) {
    final c = r[i];
    if (c == r'\' && i + 1 < r.length && r[i + 1] == '|') {
      cell.write('|');
      i++;
      continue;
    }
    if (c == '`') code = !code;
    if (c == '|' && !code) {
      cells.add(cell.toString().trim());
      cell.clear();
      continue;
    }
    cell.write(c);
  }
  cells.add(cell.toString().trim());
  return cells;
}

List<GuideBlock> _blocks(List<String> lines, int depth) {
  final out = <GuideBlock>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    final t = line.trimLeft();
    final indent = _indentOf(line);

    final fence = indent <= 3 ? _fence.firstMatch(t) : null;
    if (fence != null) {
      final marker = fence.group(1)!;
      final language = fence.group(2)!.isEmpty ? null : fence.group(2);
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(marker)) {
        final l = lines[i];
        code.add(_indentOf(l) >= indent ? l.substring(indent) : l.trimLeft());
        i++;
      }
      i++; // the closing fence
      out.add(GuideCode(code.join('\n'), language: language));
      continue;
    }

    final heading = indent <= 3 ? _heading.firstMatch(t) : null;
    if (heading != null) {
      out.add(GuideHeading(heading.group(1)!.length, parseGuideInline(heading.group(2)!)));
      i++;
      continue;
    }

    if (indent <= 3 && _rule.hasMatch(t) && !_item.hasMatch(line)) {
      out.add(const GuideRule());
      i++;
      continue;
    }

    final aside = indent <= 3 ? _aside.firstMatch(t) : null;
    if (aside != null) {
      final inner = <String>[];
      i++;
      while (i < lines.length && lines[i].trim() != ':::') {
        inner.add(lines[i]);
        i++;
      }
      i++; // the closing :::
      final title = aside.group(2);
      out.add(GuideCallout(
        depth < _maxDepth ? _blocks(inner, depth + 1) : [GuideParagraph(parseGuideInline(inner.join(' ')))],
        kind: aside.group(1)!.toLowerCase(),
        title: title == null || title.trim().isEmpty ? null : title.trim(),
      ));
      continue;
    }

    if (indent <= 3 && t.startsWith('>')) {
      final inner = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        final q = lines[i].trimLeft().substring(1);
        inner.add(q.startsWith(' ') ? q.substring(1) : q);
        i++;
      }
      out.add(GuideCallout(
          depth < _maxDepth ? _blocks(inner, depth + 1) : [GuideParagraph(parseGuideInline(inner.join(' ')))]));
      continue;
    }

    if (_item.hasMatch(line)) {
      i = _list(lines, i, out, depth);
      continue;
    }

    if (indent <= 3 && t.startsWith('|') && i + 1 < lines.length && _tableSep.hasMatch(lines[i + 1].trim())) {
      final head = [for (final c in _cells(t)) parseGuideInline(c)];
      final rows = <List<List<GuideSpan>>>[];
      i += 2;
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        rows.add([for (final c in _cells(lines[i])) parseGuideInline(c)]);
        i++;
      }
      out.add(GuideTable(head, rows));
      continue;
    }

    final image = indent <= 3 ? _imageLine.firstMatch(t) : null;
    if (image != null) {
      out.add(GuideImage(alt: _plainText(image.group(1)!), src: image.group(2)!));
      i++;
      continue;
    }

    // A paragraph: up to a blank line or the start of another block.
    final para = <String>[t.trimRight()];
    i++;
    while (i < lines.length && lines[i].trim().isNotEmpty && !_startsBlock(lines[i])) {
      para.add(lines[i].trim());
      i++;
    }
    out.add(GuideParagraph(parseGuideInline(para.join(' '))));
  }
  return out;
}

/// Reads the list starting at [start] into [out]; the line after it.
int _list(List<String> lines, int start, List<GuideBlock> out, int depth) {
  final first = _item.firstMatch(lines[start])!;
  bool isOrdered(RegExpMatch m) => RegExp(r'^\d').hasMatch(m.group(2)!);
  final ordered = isOrdered(first);
  final number = ordered ? int.tryParse(RegExp(r'\d+').firstMatch(first.group(2)!)!.group(0)!) ?? 1 : 1;
  final items = <List<GuideBlock>>[];
  var i = start;
  while (i < lines.length) {
    final m = _item.firstMatch(lines[i]);
    if (m == null || isOrdered(m) != ordered) break;
    final gap = m.group(3)!.length;
    final contentIndent = m.group(1)!.length + m.group(2)!.length + (gap > 4 ? 1 : gap);
    final item = <String>[m.group(4)!];
    i++;
    while (i < lines.length) {
      final l = lines[i];
      if (l.trim().isEmpty) {
        var j = i + 1;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j < lines.length && _indentOf(lines[j]) >= contentIndent) {
          item.add('');
          i++;
          continue;
        }
        break;
      }
      if (_indentOf(l) >= contentIndent) {
        item.add(l.substring(contentIndent));
        i++;
        continue;
      }
      if (_item.hasMatch(l) || _startsBlock(l)) break;
      item.add(l.trim()); // a paragraph's lazy next line
      i++;
    }
    items.add(depth < _maxDepth ? _blocks(item, depth + 1) : [GuideParagraph(parseGuideInline(item.join(' ')))]);
    // Blank lines between items keep the list going.
    var j = i;
    while (j < lines.length && lines[j].trim().isEmpty) {
      j++;
    }
    final next = j < lines.length ? _item.firstMatch(lines[j]) : null;
    if (next == null || isOrdered(next) != ordered) break;
    i = j;
  }
  out.add(GuideList(ordered: ordered, start: number, items: items));
  return i;
}

// ── Inline ────────────────────────────────────────────────────────────────

const _escapable = r'\`*_{}[]()#+-.!|<>~"' "'";
final _autolink = RegExp(r'^<((?:https?://|mailto:)[^\s<>]+)>');
final _entity = RegExp(r'^&(amp|lt|gt|quot|apos|nbsp|#39);');
const _entities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", '#39': "'", 'nbsp': ' '};

/// A line of a guide as runs of text: **bold**, *italic*, `code` and
/// [links](...). Anything else, HTML included, is text.
List<GuideSpan> parseGuideInline(String text) {
  final p = _Inline();
  p.run(text, 0);
  p.flush();
  return _merge(p.out);
}

/// Text a picture's alt says, without its marks.
String _plainText(String text) => parseGuideInline(text).map((s) => s.text).join();

class _Inline {
  final out = <GuideSpan>[];
  final buf = StringBuffer();
  bool bold = false;
  bool italic = false;
  String? href;

  void flush() {
    if (buf.isEmpty) return;
    out.add(GuideSpan(buf.toString(), bold: bold, italic: italic, href: href));
    buf.clear();
  }

  static bool _word(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

  void run(String s, int depth) {
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      final next = i + 1 < s.length ? s[i + 1] : '';

      if (c == r'\' && next.isNotEmpty && _escapable.contains(next)) {
        buf.write(next);
        i += 2;
        continue;
      }

      if (c == '`') {
        var n = 1;
        while (i + n < s.length && s[i + n] == '`') {
          n++;
        }
        final ticks = '`' * n;
        final end = s.indexOf(ticks, i + n);
        if (end > i) {
          flush();
          var code = s.substring(i + n, end);
          if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ')) code = code.substring(1, code.length - 1);
          out.add(GuideSpan(code, bold: bold, italic: italic, code: true, href: href));
          i = end + n;
        } else {
          buf.write(ticks);
          i += n;
        }
        continue;
      }

      if (c == '*' || c == '_') {
        final prev = i > 0 ? s[i - 1] : '';
        if (next == c) {
          final pair = '$c$c';
          if (bold) {
            flush();
            bold = false;
          } else if (s.indexOf(pair, i + 2) > i + 2 && !(c == '_' && _word(prev))) {
            flush();
            bold = true;
          } else {
            buf.write(pair);
          }
          i += 2;
          continue;
        }
        if (c == '_' && _word(prev) && _word(next)) {
          buf.write(c); // snake_case is a word, not emphasis
          i++;
          continue;
        }
        if (italic) {
          flush();
          italic = false;
          i++;
          continue;
        }
        final close = s.indexOf(c, i + 1);
        if (next.isNotEmpty && next != ' ' && close > i + 1 && !(c == '_' && _word(prev))) {
          flush();
          italic = true;
          i++;
          continue;
        }
        buf.write(c);
        i++;
        continue;
      }

      if (c == '!' && next == '[') {
        final link = _link(s, i + 1);
        if (link != null) {
          // A picture inside a line: its words, linking to it.
          flush();
          out.add(GuideSpan(link.$1.isEmpty ? link.$2 : link.$1, bold: bold, italic: italic, href: link.$2));
          i = link.$3;
          continue;
        }
      }

      if (c == '[' && href == null && depth < 4) {
        final link = _link(s, i);
        if (link != null) {
          flush();
          href = link.$2;
          run(link.$1, depth + 1);
          flush();
          href = null;
          i = link.$3;
          continue;
        }
      }

      if (c == '<') {
        final m = _autolink.firstMatch(s.substring(i));
        if (m != null) {
          flush();
          out.add(GuideSpan(m.group(1)!, bold: bold, italic: italic, href: m.group(1)));
          i += m.group(0)!.length;
          continue;
        }
      }

      if (c == '&') {
        final m = _entity.firstMatch(s.substring(i));
        if (m != null) {
          buf.write(_entities[m.group(1)]);
          i += m.group(0)!.length;
          continue;
        }
      }

      buf.write(c);
      i++;
    }
  }

  /// `[text](url "title")` at [i]: its text, its url and where it ends.
  (String, String, int)? _link(String s, int i) {
    if (s[i] != '[') return null;
    var depth = 0;
    var j = i;
    for (; j < s.length; j++) {
      if (s[j] == r'\') {
        j++;
        continue;
      }
      if (s[j] == '[') depth++;
      if (s[j] == ']') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (j >= s.length || j + 1 >= s.length || s[j + 1] != '(') return null;
    var k = j + 2;
    var parens = 1;
    for (; k < s.length; k++) {
      if (s[k] == '(') parens++;
      if (s[k] == ')') {
        parens--;
        if (parens == 0) break;
      }
    }
    if (k >= s.length) return null;
    var url = s.substring(j + 2, k).trim();
    final titled = RegExp(r'''^(\S+)\s+(?:"[^"]*"|'[^']*')$''').firstMatch(url);
    if (titled != null) url = titled.group(1)!;
    if (url.startsWith('<') && url.endsWith('>')) url = url.substring(1, url.length - 1);
    return (s.substring(i + 1, j), url, k + 1);
  }
}

/// Neighbouring runs with the same look, as one.
List<GuideSpan> _merge(List<GuideSpan> spans) {
  final out = <GuideSpan>[];
  for (final s in spans) {
    if (s.text.isEmpty) continue;
    final last = out.isEmpty ? null : out.last;
    if (last != null &&
        last.bold == s.bold &&
        last.italic == s.italic &&
        last.code == s.code &&
        last.href == s.href &&
        !s.code) {
      out[out.length - 1] = GuideSpan(last.text + s.text, bold: s.bold, italic: s.italic, href: s.href);
    } else {
      out.add(s);
    }
  }
  return out;
}

// ── Where pictures come from and links go ─────────────────────────────────

/// The address of a guide's picture, or null when it is not one the reader
/// shows. Pictures are shown only from the docs site itself, over HTTPS: a
/// picture from anywhere else would tell that place who reads which guide.
/// [src] may be written relative to the guide (`/guides/img/...`).
Uri? resolveGuideImage(String src, {required String slug}) {
  final Uri uri;
  try {
    uri = guidePageUri(slug).resolve(src.trim());
  } on FormatException {
    return null;
  }
  final origin = Uri.parse(kGuidesOrigin);
  if (uri.scheme != 'https' || uri.host != origin.host || uri.hasPort && uri.port != 443) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri.removeFragment();
}

/// Where a link in a guide goes.
sealed class GuideLinkTarget {
  const GuideLinkTarget();
}

/// Another guide, opened in the reader.
class GuideLinkToGuide extends GuideLinkTarget {
  const GuideLinkToGuide(this.slug);
  final String slug;
}

/// A page outside the app, opened in the browser (or the mail app).
class GuideLinkOutside extends GuideLinkTarget {
  const GuideLinkOutside(this.uri);
  final Uri uri;
}

/// A link that goes nowhere the reader opens (a `javascript:`, a `file:`,
/// an app's own scheme): it does nothing.
class GuideLinkNone extends GuideLinkTarget {
  const GuideLinkNone();
}

/// Where [href], in the guide at [slug], goes. A link to another guide of
/// [knownSlugs] opens in the reader; one to the web or an email address
/// opens outside the app; anything else is not followed.
GuideLinkTarget resolveGuideLink(String href, {required String slug, required Set<String> knownSlugs}) {
  final Uri uri;
  try {
    uri = guidePageUri(slug).resolve(href.trim());
  } on FormatException {
    return const GuideLinkNone();
  }
  final origin = Uri.parse(kGuidesOrigin);
  if (uri.scheme == 'https' && uri.host == origin.host) {
    final m = RegExp(r'^/guides/([a-z0-9-]+)(?:/|\.md)?$').firstMatch(uri.path);
    if (m != null && knownSlugs.contains(m.group(1)) && uri.fragment.isEmpty) return GuideLinkToGuide(m.group(1)!);
  }
  if (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto') {
    if (uri.scheme != 'mailto' && uri.host.isEmpty) return const GuideLinkNone();
    return GuideLinkOutside(uri);
  }
  return const GuideLinkNone();
}
