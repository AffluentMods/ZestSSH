import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/hosts_page_prefs.dart';
import 'package:zestssh/features/hosts/widgets/hosts_table.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('the workspaces header button', () {
    Future<void> pump(WidgetTester tester, double width) => tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Flexible(child: SaveLayoutButton(hasSession: true, onSave: () {}))],
                ),
              ),
            ),
          ),
        ));

    testWidgets('has its words whole, or only its icon and a tooltip, never "Save cur…"', (tester) async {
      await pump(tester, 800);
      expect(find.text(en.workspaceSaveCurrentLayout), findsOneWidget);
      await pump(tester, 70);
      expect(find.text(en.workspaceSaveCurrentLayout), findsNothing);
      expect(find.byIcon(LucideIcons.save), findsOneWidget);
      expect(find.byTooltip(en.workspaceSaveCurrentLayout), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test("the hosts list gives its width to the address first, and a longer language's Last used room", () {
    expect(hostsColumnFlex(HostsListColumn.address), greaterThan(hostsColumnFlex(HostsListColumn.health)));
    expect(hostsColumnFlex(HostsListColumn.lastUsed), greaterThan(hostsColumnFlex(HostsListColumn.tags)));
  });

  test('a host is a host on a phone too, in every language', () {
    for (final l in AppLocalizations.supportedLocales) {
      final s = lookupAppLocalizations(l);
      expect(s.connectionPreviewNewName, s.hostsNewHost, reason: '$l');
    }
    expect(en.connectionSaveConnection, 'Save host');
    expect(en.snippetsNoneDesc, isNot(contains('frequently-used')));
    expect(en.homePortForwardEmptyDesc, isNot(contains('Pre-configure')));
    expect(en.connectionPortForwardingDesc, isNot(contains('Pre-configure')));
  });

  test('the tier is called by its name beside Unlock with Squeezed, in every language', () {
    for (final l in AppLocalizations.supportedLocales) {
      final s = lookupAppLocalizations(l);
      expect(s.settingsInlineCustomAppThemesDescFree, contains('Squeezed'), reason: '$l');
      expect(s.settingsInlineCustomTerminalThemesDescFree, contains('Squeezed'), reason: '$l');
    }
  });

  test('the join review names the code by its start, with no ellipsis before the full stop', () {
    expect(reviewCodeStart('ZEST5TCJABCD'), 'ZEST-5TCJ');
    expect(en.reviewKeysCheckedBody(reviewCodeStart('ZEST5TCJABCD')), startsWith('You made ZEST-5TCJ. It is'));
  });

  test('Wi-Fi is written one way, the name in double quotes where the language uses them', () {
    expect(en.networksTriggerSummarySsid('Office'), 'Wi-Fi "Office"');
    for (final l in AppLocalizations.supportedLocales) {
      expect(lookupAppLocalizations(l).networksTriggerSummarySsid('Office'), isNot(contains('WiFi')), reason: '$l');
    }
  });
}
