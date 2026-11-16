import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/help/guides/guide_markdown.dart';

/// The guides' Markdown, read into blocks the reader draws natively (Help >
/// Guides, 3.0). Nothing in a guide is run: HTML is text, pictures come from
/// the docs site only, and links go to another guide or outside the app.
void main() {
  const guide = '''---
title: Networks and jump hosts
summary: A summary.
keywords: [network]
features: [networks]
applies_to: 3.0.0
---

## In plain words

A **network** is a place. Use `10.0.1.0/24` and see [Networks](/features/networks/overview/).

## Set it up

### On a computer

1. Open **Networks** in the side rail.
2. Press **New network**.

   ![Step 2: the Networks page](/guides/img/networks/desktop.webp)

3. Save it.
   It is saved at once.

- A bullet
- Another

```bash
ssh -J jump@bastion.example.com me@10.0.1.5
```

> A quote.

:::note[Heads up]
Inside a note.
:::

| In PuTTY | In ZestSSH |
|---|---|
| Session | **New host** |

---
''';

  test('frontmatter is left out and the blocks come in order', () {
    final blocks = parseGuideMarkdown(guide);
    expect(blocks.first, isA<GuideHeading>());
    expect((blocks.first as GuideHeading).text, 'In plain words');
    expect(blocks.whereType<GuideHeading>().map((h) => '${h.level} ${h.text}'),
        ['2 In plain words', '2 Set it up', '3 On a computer']);
    expect(stripFrontmatter(guide), startsWith('\n## In plain words'));
    expect(frontmatterTitle(guide), 'Networks and jump hosts');
  });

  test('bold, inline code and links are runs of their own', () {
    final p = parseGuideMarkdown(guide).whereType<GuideParagraph>().first;
    expect(p.spans.map((s) => '$s'), [
      'A ',
      '[b]network',
      ' is a place. Use ',
      '[c]10.0.1.0/24',
      ' and see ',
      '[a(/features/networks/overview/)]Networks',
      '.',
    ]);
  });

  test('a numbered list keeps its numbers, and a step holds its picture and its next line', () {
    final lists = parseGuideMarkdown(guide).whereType<GuideList>().toList();
    final steps = lists.first;
    expect(steps.ordered, isTrue);
    expect(steps.start, 1);
    expect(steps.items, hasLength(3));
    final second = steps.items[1];
    expect((second.first as GuideParagraph).text, 'Press New network.');
    final picture = second[1] as GuideImage;
    expect(picture.alt, 'Step 2: the Networks page');
    expect(picture.src, '/guides/img/networks/desktop.webp');
    expect((steps.items[2].single as GuideParagraph).text, 'Save it. It is saved at once.');
    final bullets = lists[1];
    expect(bullets.ordered, isFalse);
    expect(bullets.items, hasLength(2));
  });

  test('a list that starts at another number keeps it', () {
    final list = parseGuideMarkdown('3. Third\n4. Fourth\n').single as GuideList;
    expect(list.start, 3);
  });

  test('code, quotes, notes, tables and rules', () {
    final blocks = parseGuideMarkdown(guide);
    final code = blocks.whereType<GuideCode>().single;
    expect(code.language, 'bash');
    expect(code.code, 'ssh -J jump@bastion.example.com me@10.0.1.5');
    final callouts = blocks.whereType<GuideCallout>().toList();
    expect(callouts.first.kind, isNull);
    expect((callouts.first.children.single as GuideParagraph).text, 'A quote.');
    expect(callouts[1].kind, 'note');
    expect(callouts[1].title, 'Heads up');
    final table = blocks.whereType<GuideTable>().single;
    expect(table.head.map((c) => c.map((s) => s.text).join()), ['In PuTTY', 'In ZestSSH']);
    expect('${table.rows.single[1].single}', '[b]New host');
    expect(blocks.last, isA<GuideRule>());
  });

  test('HTML is never read as HTML: it is the text it is', () {
    final blocks = parseGuideMarkdown('<script>alert(1)</script>\n\n'
        'Hello <img src="https://tracker.example/p.gif" onerror="x()"> there\n\n'
        '<iframe src="https://evil.example"></iframe>\n');
    expect(blocks, hasLength(3));
    expect(blocks.every((b) => b is GuideParagraph), isTrue);
    expect((blocks[0] as GuideParagraph).text, '<script>alert(1)</script>');
    expect((blocks[1] as GuideParagraph).text, contains('<img src="https://tracker.example/p.gif"'));
    expect(blocks.whereType<GuideImage>(), isEmpty);
    // No run of it is a link either.
    for (final b in blocks) {
      expect((b as GuideParagraph).spans.every((s) => s.href == null), isTrue);
    }
  });

  test('escapes, entities, snake_case and unclosed marks are text', () {
    final spans = parseGuideInline(r'Edit authorized_keys \*not bold\* a &amp; b **open');
    expect(spans.map((s) => s.text).join(), 'Edit authorized_keys *not bold* a & b **open');
    expect(spans.every((s) => !s.bold && !s.italic), isTrue);
  });

  test('autolinks and links with titles', () {
    expect(parseGuideInline('<https://zestssh.com/download>').single.href, 'https://zestssh.com/download');
    expect(parseGuideInline('[x](https://example.com/a "A title")').single.href, 'https://example.com/a');
  });

  group('pictures come from the docs site only', () {
    Uri? img(String src) => resolveGuideImage(src, slug: 'networks-and-jump-hosts');

    test('a picture of the docs site, written relative or whole', () {
      expect(img('/guides/img/x/a.webp').toString(), 'https://docs.zestssh.com/guides/img/x/a.webp');
      expect(img('https://docs.zestssh.com/guides/img/x/a.webp').toString(),
          'https://docs.zestssh.com/guides/img/x/a.webp');
      expect(img('../img/a.webp').toString(), 'https://docs.zestssh.com/guides/img/a.webp');
    });

    test('anything else is not loaded', () {
      for (final src in [
        'https://tracker.example/pixel.gif',
        '//tracker.example/pixel.gif',
        'http://docs.zestssh.com/guides/img/a.webp',
        'https://docs.zestssh.com.evil.example/a.webp',
        'https://user@docs.zestssh.com/a.webp',
        'https://docs.zestssh.com:8443/a.webp',
        'data:image/png;base64,AAAA',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(img(src), isNull, reason: src);
      }
    });
  });

  group('where a link goes', () {
    GuideLinkTarget go(String href) =>
        resolveGuideLink(href, slug: 'networks-and-jump-hosts', knownSlugs: {'keys', 'sftp'});

    test('another guide opens in the reader', () {
      expect((go('/guides/keys/') as GuideLinkToGuide).slug, 'keys');
      expect((go('https://docs.zestssh.com/guides/sftp/') as GuideLinkToGuide).slug, 'sftp');
      expect((go('/guides/keys.md') as GuideLinkToGuide).slug, 'keys');
    });

    test('a docs page, the web and email open outside the app', () {
      expect((go('/features/networks/overview/') as GuideLinkOutside).uri.toString(),
          'https://docs.zestssh.com/features/networks/overview/');
      expect((go('/guides/setting-up-jump-hosts/') as GuideLinkOutside).uri.host, 'docs.zestssh.com');
      expect((go('https://zestssh.com/whitepaper/whitepaper.pdf') as GuideLinkOutside).uri.host, 'zestssh.com');
      expect((go('mailto:support@zestssh.com') as GuideLinkOutside).uri.scheme, 'mailto');
      // A guide's own part opens the web page there.
      expect(go('/guides/keys/#how-it-works'), isA<GuideLinkOutside>());
    });

    test('a script, a file or an app link is not followed', () {
      for (final href in ['javascript:alert(1)', 'file:///etc/passwd', 'zestssh://run?cmd=rm', 'data:text/html,x', 'http:']) {
        expect(go(href), isA<GuideLinkNone>(), reason: href);
      }
    });
  });

  test('a page that nests deeper than any guide is read without running away', () {
    final deep = List.generate(40, (i) => '${'  ' * i}- level $i').join('\n');
    expect(() => parseGuideMarkdown(deep), returnsNormally);
    final quotes = '${'> ' * 50}deep';
    expect(() => parseGuideMarkdown(quotes), returnsNormally);
  });
}
