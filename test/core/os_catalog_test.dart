import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/data/host_icon_svgs.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/os_descriptor.dart';
import 'package:zestssh/core/widgets/os_icon.dart';

/// Ids that existed before the line-icon set. They are persisted in
/// `connections.icon_id` (synced to every device) and produced by OS
/// detection, so renaming one silently resets every host that uses it.
const _legacyIds = [
  // generic
  'server', 'server_rack', 'database', 'router', 'firewall', 'nas', 'cloud',
  'vm', 'kubernetes', 'network', 'cpu', 'web', 'shell', 'game_server', 'mail',
  'desktop', 'access_point', 'file_server', 'git',
  // brand marks
  'ubuntu', 'debian', 'fedora', 'rhel', 'centos', 'rocky', 'alma', 'alpine',
  'arch', 'manjaro', 'opensuse', 'sles', 'gentoo', 'void', 'nixos', 'kali',
  'parrot', 'mint', 'pop', 'macos', 'windows', 'freebsd', 'openbsd', 'netbsd',
  'proxmox', 'truenas', 'unraid', 'esxi', 'raspberry_pi', 'home_assistant',
  'container',
];

/// The inline SVG a descriptor renders, pulled back out of its builder.
String _svgOf(OsDescriptor d) {
  final w = d.iconBuilder(24, Colors.white) as SvgPicture;
  return (w.bytesLoader as SvgStringLoader).provideSvg(null);
}

void main() {
  group('OsCatalog', () {
    test('every legacy id still resolves to itself', () {
      for (final id in _legacyIds) {
        expect(OsCatalog.get(id).id, id, reason: id);
      }
    });

    test('ids are unique and lower-case snake case', () {
      final ids = OsCatalog.pickable.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final id in ids) {
        expect(RegExp(r'^[a-z0-9]+(_[a-z0-9]+)*$').hasMatch(id), isTrue,
            reason: id);
      }
      expect(ids, isNot(contains('unknown')));
    });

    test('get falls back to unknown and ignores case', () {
      expect(OsCatalog.get(null).id, 'unknown');
      expect(OsCatalog.get('').id, 'unknown');
      expect(OsCatalog.get('no-such-icon').id, 'unknown');
      expect(OsCatalog.get('Ubuntu').id, 'ubuntu');
      expect(OsCatalog.get('SERVER_RACK').id, 'server_rack');
    });

    test('every generated brand mark has a descriptor in the OS section', () {
      for (final id in kHostBrandIconSvgs.keys) {
        final d = OsCatalog.get(id);
        expect(d.id, id, reason: id);
        expect(d.category, HostIconCategory.os, reason: id);
        expect(_svgOf(d), kHostBrandIconSvgs[id], reason: id);
      }
    });

    test('every generated line icon is offered by some descriptor', () {
      final offered = OsCatalog.pickable.map(_svgOf).toSet();
      for (final entry in kHostLineIconSvgs.entries) {
        // The generic container glyph shares its id with the Docker brand
        // mark, which wins; the Containers icon covers the generic case.
        if (entry.key == 'container') continue;
        expect(offered, contains(entry.value), reason: entry.key);
      }
    });

    test('every category has icons and inCategory partitions pickable', () {
      var total = 0;
      for (final c in HostIconCategory.values) {
        final icons = OsCatalog.inCategory(c);
        expect(icons, isNotEmpty, reason: c.name);
        for (final d in icons) {
          expect(d.category, c);
        }
        total += icons.length;
      }
      expect(total, OsCatalog.pickable.length);
    });

    test('every descriptor has a name and an opaque colour', () {
      for (final d in OsCatalog.pickable) {
        expect(d.displayName.trim(), isNotEmpty, reason: d.id);
        expect(d.brandColor.a, 1.0, reason: d.id);
      }
    });

    test('search matches id, name, keywords and category', () {
      expect(OsCatalog.search(''), OsCatalog.pickable);
      expect(OsCatalog.search('   '), OsCatalog.pickable);
      expect(OsCatalog.search('k8s').map((d) => d.id), contains('kubernetes'));
      expect(OsCatalog.search('Docker').map((d) => d.id),
          containsAll(['container', 'containers']));
      expect(OsCatalog.search('server rack').map((d) => d.id),
          contains('server_rack'));
      expect(OsCatalog.search('Raspberry').map((d) => d.id),
          contains('raspberry_pi'));
      // Every word has to hit.
      expect(OsCatalog.search('ubuntu router'), isEmpty);
      expect(OsCatalog.search('zzzz'), isEmpty);
      // Category names are searchable too.
      final security = OsCatalog.search('security');
      expect(security.map((d) => d.id), containsAll(['shield', 'kali']));
    });

    test('generated svgs carry no scripts, links or embedded images', () {
      final all = {...kHostLineIconSvgs, ...kHostBrandIconSvgs};
      expect(all.length, 160);
      for (final entry in all.entries) {
        final svg = entry.value;
        expect(svg.startsWith('<svg'), isTrue, reason: entry.key);
        expect(svg.contains('<script'), isFalse, reason: entry.key);
        expect(svg.contains('<image'), isFalse, reason: entry.key);
        expect(svg.contains('xlink:'), isFalse, reason: entry.key);
        expect(svg.contains('<metadata'), isFalse, reason: entry.key);
        expect(svg.contains('javascript:'), isFalse, reason: entry.key);
      }
    });
  });

  group('OsIcon', () {
    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('tints glyph and tile with the colour it is given', (tester) async {
      const tint = Color(0xFF12AB34);
      await tester.pumpWidget(
          wrap(const OsIcon(osId: 'ubuntu', size: 36, color: tint)));
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.colorFilter, const ColorFilter.mode(tint, BlendMode.srcIn));
      final box = tester.widget<Container>(find.descendant(
        of: find.byType(OsIcon),
        matching: find.byType(Container),
      ));
      final deco = box.decoration! as BoxDecoration;
      expect(deco.color, tint.withValues(alpha: 0.18));
    });

    testWidgets('is in its own colour when given none',
        (tester) async {
      await tester.pumpWidget(wrap(const OsIcon(osId: 'ubuntu', size: 36)));
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.colorFilter,
          ColorFilter.mode(OsCatalog.get('ubuntu').brandColor, BlendMode.srcIn));
      expect(OsIcon.ownColor(OsCatalog.get('ubuntu')), OsCatalog.get('ubuntu').brandColor,
          reason: 'Ubuntu\'s orange shows on the theme the tests run on');
    });

    testWidgets('HostIcon prefers the chosen id over the detected OS',
        (tester) async {
      await tester.pumpWidget(wrap(const HostIcon(
        iconId: 'firewall',
        osId: 'debian',
      )));
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect((svg.bytesLoader as SvgStringLoader).provideSvg(null),
          kHostLineIconSvgs['firewall']);
    });
  });
}
