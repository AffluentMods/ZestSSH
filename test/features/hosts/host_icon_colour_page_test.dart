import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// The Hosts page, from the saved host to what is drawn (3.0):
/// a host's icon is in its own colour whatever its group or
/// its label, unless the person had it follow the label or gave it a colour;
/// on its card, at every card size, and in its panel.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

const _blue = Color(0xFF3B82F6);
const _pink = Color(0xFFEC4899);
const _green = Color(0xFF22C55E);
// A 1x1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // Debian's own colour as it is drawn: a shade of the brand's that shows.
  final debian = OsIcon.ownColor(OsCatalog.get('debian'));

  Future<AppDatabase> pump(WidgetTester tester, {int sizeTier = 1, Map<String, Object> kept = const {}}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(kept);
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 8);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
          id: 'g-web',
          name: 'Web',
          colorValue: Value(_blue.toARGB32()),
          createdAt: now,
          updatedAt: Value(now),
        ));
    for (final (id, label, group, labelColor, iconColor, picture) in <(String, String, String?, int?, int?, String?)>[
      ('own', 'web-01', 'g-web', null, null, null),
      ('follows', 'web-02', 'g-web', null, HostIconColor.followsLabel, null),
      ('label', 'db-primary', 'g-web', _pink.toARGB32(), HostIconColor.followsLabel, null),
      ('own-label', 'cache-01', 'g-web', _pink.toARGB32(), null, null),
      ('custom', 'build-runner', 'g-web', null, HostIconColor.custom(_green), null),
      ('bare', 'edge-router', null, null, HostIconColor.followsLabel, null),
      ('picture', 'mac-studio', 'g-web', null, HostIconColor.custom(_green), _png),
    ]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: '192.168.10.${20 + label.length}',
            port: const Value(22),
            groupId: Value(group),
            colorValue: Value(labelColor),
            iconId: const Value('debian'),
            customIcon: Value(picture),
            iconColor: Value(iconColor),
            sizeTier: Value(sizeTier),
            createdAt: now,
            updatedAt: now,
          ));
    }
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}, onSwitchToSession: (_) {}),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return db;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// The colour the glyph of the icon under [within] is drawn in.
  Color glyphIn(WidgetTester tester, Finder within) {
    final icon = find.descendant(of: within, matching: find.byType(HostIcon));
    expect(icon, findsOneWidget);
    final svg = tester.widget<SvgPicture>(find.descendant(of: icon, matching: find.byType(SvgPicture)));
    for (final c in [_blue, _pink, _green, debian]) {
      if (svg.colorFilter == ColorFilter.mode(c, BlendMode.srcIn)) return c;
    }
    fail('the glyph is in none of the colours of this test: ${svg.colorFilter}');
  }

  // By the host, not by its name: a small card shows the icon alone.
  Finder card(String id) => find.byWidgetPredicate((w) => w is HostCard && w.data.id == id);

  Future<void> open(WidgetTester tester, String name) async {
    await tester.tap(find.text(name).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }

  Color tileOf(WidgetTester tester) {
    final tile = tester.widget<Container>(find.byKey(const ValueKey('host-panel-icon-tile')));
    return (tile.decoration! as BoxDecoration).color!;
  }

  // Every host is one card now; a size saved before (1 the full card, 0 the old
  // row, 3 the old square) is not read, and changes nothing.
  for (final (tier, name) in [(1, 'a host saved as a large card'), (0, 'a host saved as a medium card'), (3, 'a host saved as a small card')]) {
    testWidgets('on $name: the icon\'s own colour unless the person chose otherwise', (tester) async {
      expect({debian, _blue, _pink, _green}.length, 4, reason: 'four colours that can be told apart');
      await pump(tester, sizeTier: tier);
      // In a group with a colour, and nothing chosen: its own colour. This is
      // what was asked for; the icon used to take the group's.
      expect(glyphIn(tester, card('own')), debian);
      // A colour label of its own changes nothing about that.
      expect(glyphIn(tester, card('own-label')), debian);
      // Following the label: the group's colour, or the host's own label over it.
      expect(glyphIn(tester, card('follows')), _blue);
      expect(glyphIn(tester, card('label')), _pink);
      // A colour of its own.
      expect(glyphIn(tester, card('custom')), _green);
      // Following the label of a host with no label and no group: its own.
      expect(glyphIn(tester, card('bare')), debian);
      // An uploaded picture is a picture.
      final picture = find.descendant(of: card('picture'), matching: find.byType(HostIcon));
      expect(find.descendant(of: picture, matching: find.byType(Image)), findsOneWidget);
      expect(find.descendant(of: picture, matching: find.byType(SvgPicture)), findsNothing);
      await finish(tester);
    });
  }

  testWidgets('the card still shows the group\'s colour on its rail: only the icon went back to its own', (tester) async {
    // The rail where Settings has it in the host's colour (none by default
    // since 4.0).
    await pump(tester, kept: {
      'host_card_settings': jsonEncode(const HostCardSettings(accentMode: HostCardAccentMode.group).toJson()),
    });
    // The rail lies over the card's edge (host_card.dart, 'host-card-rail').
    final rails = tester
        .widgetList<ColoredBox>(find.descendant(
          of: find.descendant(of: card('own'), matching: find.byKey(const ValueKey('host-card-rail'))),
          matching: find.byType(ColoredBox),
        ))
        .where((c) => c.color == _blue);
    expect(rails, isNotEmpty, reason: 'the rail of a host in a blue group');
    await finish(tester);
  });

  testWidgets('in the panel: the icon and the tile behind it are in the icon\'s colour', (tester) async {
    await pump(tester);
    Finder panel(String id) => find.byKey(ValueKey('host-panel-$id'));

    await open(tester, 'web-01');
    expect(glyphIn(tester, panel('own')), debian);
    expect(tileOf(tester), debian.withValues(alpha: 0.16), reason: 'one colour, not the icon\'s on the group\'s');

    await open(tester, 'web-02');
    expect(glyphIn(tester, panel('follows')), _blue);
    expect(tileOf(tester), _blue.withValues(alpha: 0.16));

    await open(tester, 'db-primary');
    expect(glyphIn(tester, panel('label')), _pink);
    expect(tileOf(tester), _pink.withValues(alpha: 0.16));

    await open(tester, 'build-runner');
    expect(glyphIn(tester, panel('custom')), _green);
    expect(tileOf(tester), _green.withValues(alpha: 0.16));

    await open(tester, 'edge-router');
    expect(glyphIn(tester, panel('bare')), debian);
    expect(tileOf(tester), debian.withValues(alpha: 0.16));

    // Behind an uploaded picture, which has no one colour, the tile is in the host's.
    await open(tester, 'mac-studio');
    expect(tileOf(tester), _blue.withValues(alpha: 0.16));
    await finish(tester);
  });

  testWidgets('a host searched out of the grid is drawn the same in its panel', (tester) async {
    await pump(tester);
    await open(tester, 'web-02');
    await tester.enterText(find.byType(TextField).first, 'edge');
    await tester.pump(const Duration(milliseconds: 400));
    expect(card('follows'), findsNothing, reason: 'no longer in the grid');
    expect(card('bare'), findsOneWidget);
    final panel = find.byKey(const ValueKey('host-panel-follows'));
    expect(panel, findsOneWidget);
    expect(glyphIn(tester, panel), _blue, reason: 'its group\'s colour, though the grid no longer shows it');
    expect(tileOf(tester), _blue.withValues(alpha: 0.16));
    await finish(tester);
  });
}
