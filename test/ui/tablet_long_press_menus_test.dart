import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_locations_rail.dart';

/// Where the controls are touch sized (a tablet, 4.0),
/// a long press opens what a right click opens, a finger having no right
/// button: here the SFTP locations rail's empty area (its New bookmark menu).
/// A computer's long press opens nothing, as before; its right click does.
void main() {
  Future<List<Offset>> pumpRail(WidgetTester tester, {required bool touch}) async {
    final asked = <Offset>[];
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(compact: !touch),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 220,
            height: 500,
            // Both panes' places, each its own part of the rail (the dual
            // pane's), the first with its empty area's menu.
            child: SftpLocationsRail(
              groups: [
                RailGroup(
                  label: 'web-01',
                  items: [RailItem(icon: LucideIcons.home, label: 'Home', onTap: () {})],
                  onEmptyAreaMenu: asked.add,
                ),
                RailGroup(
                  label: 'This computer',
                  items: [RailItem(icon: LucideIcons.home, label: 'Desktop', onTap: () {})],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return asked;
  }

  /// Under the first part's last row, in its empty area.
  Offset emptyArea(WidgetTester tester) {
    final list = tester.getRect(
      find.descendant(of: find.byType(SftpLocationsRail), matching: find.byType(ListView)).first,
    );
    return Offset(list.center.dx, list.bottom - 10);
  }

  testWidgets("the rail's empty area: a long press opens its menu where the controls are touch sized", (tester) async {
    final asked = await pumpRail(tester, touch: true);
    await tester.longPressAt(emptyArea(tester));
    await tester.pumpAndSettle();
    expect(asked, hasLength(1));
  });

  testWidgets("a computer's: a long press opens nothing, a right click does", (tester) async {
    final asked = await pumpRail(tester, touch: false);
    await tester.longPressAt(emptyArea(tester));
    await tester.pumpAndSettle();
    expect(asked, isEmpty);
    await tester.tapAt(emptyArea(tester), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(asked, hasLength(1));
  });
}
