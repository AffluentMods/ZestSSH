import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/features/help/guides/guide_search.dart';
import 'package:zestssh/features/help/guides/guides_index.g.dart';

import '../../../tool/guides_index.dart';

/// Help > Guides (3.0: a search for
/// "network" finds the Networks guide). The index is compiled in from the
/// guides' frontmatter, and search finds a guide by its title, its keywords
/// and their synonyms, and its summary.
void main() {
  List<String> slugs(String q) => [for (final g in searchGuides(q)) g.slug];

  group('search', () {
    test('"network" finds Networks and jump hosts first', () {
      expect(slugs('network').first, 'networks-and-jump-hosts');
      expect(slugs('Networks').first, 'networks-and-jump-hosts');
      expect(slugs('  NETWORK ').first, 'networks-and-jump-hosts');
    });

    test('a synonym finds the guide that lists it', () {
      expect(slugs('bastion').first, 'networks-and-jump-hosts');
      expect(slugs('tailscale').first, 'networks-and-jump-hosts');
      expect(slugs('wifi'), contains('networks-and-jump-hosts'));
      expect(slugs('scp').first, 'sftp');
      expect(slugs('upload files').first, 'sftp');
      expect(slugs('tunnel'), contains('port-forwarding'));
      expect(slugs('socks').first, 'port-forwarding');
      expect(slugs('yubikey').first, 'keys');
      expect(slugs('putty'), contains('import-from-other-apps'));
      expect(slugs('qr'), contains('joining-a-team'));
      expect(slugs('webdav').first, 'sync-and-backups');
    });

    test('plural and singular are one word, and a word being typed matches', () {
      expect(slugs('key'), contains('keys'));
      expect(slugs('keys').first, 'keys');
      expect(slugs('net'), contains('networks-and-jump-hosts'));
      expect(slugs('snip').first, 'snippets-and-workflows');
    });

    test('every word must be found: a word no guide has leaves nothing', () {
      expect(searchGuides('kubernetes helm chart'), isEmpty);
      expect(searchGuides('network zzzz'), isEmpty);
    });

    test('an empty query, or one of only marks, lists every guide in its order', () {
      expect(searchGuides(''), kGuidesIndex);
      expect(searchGuides(' - '), kGuidesIndex);
    });

    test('a whole keyword of several words ranks its guide first', () {
      expect(slugs('jump host').first, 'networks-and-jump-hosts');
      expect(slugs('api key').first, 'automation-and-api-keys');
    });

    test('the index is small, complete and well formed', () {
      expect(kGuidesIndex.length, greaterThanOrEqualTo(20));
      final seen = <String>{};
      for (final g in kGuidesIndex) {
        expect(kGuideSlug.hasMatch(g.slug), isTrue, reason: g.slug);
        expect(seen.add(g.slug), isTrue, reason: '${g.slug} twice');
        expect(g.title, isNotEmpty);
        expect(g.summary, isNotEmpty);
        expect(g.keywords, isNotEmpty);
        expect(g.features, isNotEmpty);
        // 3.0's guides, and 4.0's (remote screens).
        expect(g.appliesTo, anyOf('3.0.0', '4.0.0'), reason: g.slug);
        expect(g.markdownUri.toString(), 'https://docs.zestssh.com/guides/${g.slug}.md');
        expect(g.pageUri.toString(), 'https://docs.zestssh.com/guides/${g.slug}/');
      }
      // The app's major features, each with its guide.
      for (final slug in [
        'hosts-and-connecting', 'keys', 'sftp', 'port-forwarding', 'networks-and-jump-hosts',
        'snippets-and-workflows', 'automation-and-api-keys', 'alerts', 'history-and-suggestions',
        'server-monitor', 'sync-and-backups', 'team-create-and-invite', 'team-roles-and-vaults',
        'team-rules', 'joining-a-team', 'session-sharing', 'certificates', 'themes',
        'import-from-other-apps', 'phones-and-tablets',
      ]) {
        expect(guideBySlug(slug), isNotNull, reason: slug);
      }
      expect(guideIndexProblems([
        for (final g in kGuidesIndex)
          GuideFrontmatter(
            slug: g.slug,
            title: g.title,
            summary: g.summary,
            keywords: g.keywords,
            platforms: g.platforms,
            features: g.features,
            appliesTo: g.appliesTo,
            order: 0,
          ),
      ]), isEmpty);
    });

    test('a slug that is not one is refused before any address is made', () {
      for (final bad in ['', '../etc', 'a/b', 'Keys', 'keys.md', 'a b', 'https://x.example']) {
        expect(() => guideMarkdownUri(bad), throwsArgumentError, reason: bad);
      }
    });
  });

  group('the "?" deep links', () {
    test('every feature id a page names opens a guide', () {
      // Every `feature: '...'` given to GuideHelpButton or GuideTitle, the
      // Team pages' ids and the Settings headers' `guide:` ids, read from the
      // source, so that a "?" can never lead nowhere.
      final ids = <String>{};
      final named = RegExp(r"""(?:GuideHelpButton|GuideTitle)\([^;]*?feature: '([a-z_]+)'""", dotAll: true);
      final team = RegExp(r"""TeamPage\.[a-zA-Z| .]+ => '([a-z_]+)'""");
      final settings = RegExp(r"""_SettingsSection\.\w+ => '([a-z_]+)'""");
      final guideArg = RegExp(r"""\bguide: '([a-z_]+)'""");
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        for (final re in [named, team, settings, guideArg]) {
          for (final m in re.allMatches(text)) {
            ids.add(m.group(1)!);
          }
        }
      }
      expect(ids, containsAll(['hosts', 'keys', 'port_forwards', 'networks', 'snippets', 'alerts', 'automation',
          'monitor', 'sync', 'themes', 'api_keys', 'team_overview', 'team_members', 'team_roles', 'team_vaults',
          'team_rules', 'team_seats', 'team_sign_in', 'team_trust', 'team']));
      for (final id in ids) {
        expect(guideForFeature(id), isNotNull, reason: 'a "?" for $id opens no guide');
      }
    });

    test('each page opens the guide that is about it', () {
      expect(guideForFeature('networks')!.slug, 'networks-and-jump-hosts');
      expect(guideForFeature('hosts')!.slug, 'hosts-and-connecting');
      expect(guideForFeature('port_forwards')!.slug, 'port-forwarding');
      expect(guideForFeature('alerts')!.slug, 'alerts');
      expect(guideForFeature('monitor')!.slug, 'server-monitor');
      expect(guideForFeature('sync')!.slug, 'sync-and-backups');
      expect(guideForFeature('team_vaults')!.slug, 'team-roles-and-vaults');
      expect(guideForFeature('team_rules')!.slug, 'team-rules');
      expect(guideForFeature('nothing_of_ours'), isNull);
    });
  });

  group('the index tool', () {
    test('reads the guides\' frontmatter as they write it', () {
      final fm = readFrontmatter('---\n'
          'title: Networks and jump hosts\n'
          "summary: 'Reach a host, it''s easy.'\n"
          'keywords: [network, lan, "wi-fi"]\n'
          'features: [networks]\n'
          'applies_to: 3.0.0\n'
          '---\n\n## In plain words\n')!;
      expect(fm['title'], 'Networks and jump hosts');
      expect(fm['summary'], "Reach a host, it's easy.");
      expect(fm['keywords'], ['network', 'lan', 'wi-fi']);
      expect(fm['features'], ['networks']);
      expect(fm['applies_to'], '3.0.0');
      expect(readFrontmatter('## No frontmatter'), isNull);
    });

    test('finds a feature id given to two guides, and empty fields', () {
      GuideFrontmatter g(String slug, List<String> features, {String summary = 'x'}) => GuideFrontmatter(
          slug: slug, title: 'T', summary: summary, keywords: ['k'], platforms: [], features: features,
          appliesTo: '3.0.0', order: 1);
      expect(guideIndexProblems([g('a', ['x']), g('b', ['x'])]), ['feature x is given to a and b']);
      expect(guideIndexProblems([g('Bad Slug', ['y'], summary: '')]),
          containsAll(['Bad Slug: not a slug the app fetches', 'Bad Slug: no summary']));
    });

    test('writes Dart that quotes what it must', () {
      final src = guidesIndexSource([
        GuideFrontmatter(slug: 'a', title: r"It's $5 \ more", summary: 's', keywords: ['k'], platforms: ['phone'],
            features: ['f'], appliesTo: '3.0.0', order: 1),
      ]);
      expect(src, contains(r"title: 'It\'s \$5 \\ more',"));
      expect(src, contains("platforms: ['phone'],"));
    });

    test('the compiled index is the docs\' guides, where the docs are beside this repository', () {
      final dir = Directory('../ZestSSH-Docs/src/content/docs/guides');
      if (!dir.existsSync()) {
        markTestSkipped('the docs repository is not beside this one');
        return;
      }
      final source = guidesIndexSource(readGuides(dir));
      expect(File(indexPath).readAsStringSync().replaceAll('\r\n', '\n'), source,
          reason: 'run: dart tool/guides_index.dart');
    });
  });
}
