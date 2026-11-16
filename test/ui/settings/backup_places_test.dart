import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/backup_destination_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/services/backup/google_drive_destination.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart' show BackupPlaces, showBackupPlacesDialog;

/// The places automatic backups are copied to (found in a review): a
/// WebDAV server could be added only in a phone's Settings, so a computer had
/// no way, and no screen anywhere added Google Drive though the backups knew
/// how to use it. The places are one widget now, in the phone's backup sheet
/// and in a dialog from the account page; Google Drive is offered on a phone.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: home),
      ),
    ));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  }

  testWidgets('a computer opens them from the account page and can add a WebDAV server', (tester) async {
    await pump(
      tester,
      Builder(builder: (context) => TextButton(onPressed: () => showBackupPlacesDialog(context), child: const Text('open'))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(en.accountBackupPlaces), findsOneWidget);
    expect(find.text(en.settingsMobThisDevice), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup-add-webdav')));
    await tester.pumpAndSettle();
    expect(find.text(en.settingsMobWebDavNextcloud), findsOneWidget, reason: 'the WebDAV form');
  });

  testWidgets('Google Drive is offered where its sign-in works, added once, and a sign-in that fails is said', (tester) async {
    var fail = true;
    final container = await pump(
      tester,
      BackupPlaces(
        offerGoogleDrive: true,
        connectGoogleDrive: () async {
          if (fail) throw StateError('Google Sign-In was cancelled by the user.');
          return GoogleDriveBackupDestination();
        },
      ),
    );
    final add = find.byKey(const ValueKey('backup-add-google-drive'));
    expect(add, findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, en.backupGoogleDriveNotAdded);
    expect(notice.details, contains('cancelled by the user'), reason: 'why, to copy');
    expect(await container.read(backupDestinationsProvider.future), isEmpty);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    fail = false;
    await tester.tap(add);
    await tester.pumpAndSettle();
    final places = await container.read(backupDestinationsProvider.future);
    expect([for (final BackupDestination d in places) d.name], ['google_drive']);
    expect(find.text('Google Drive'), findsOneWidget, reason: 'listed');
    expect(add, findsNothing, reason: 'one Google Drive place');
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
  });

  testWidgets('a computer is not offered Google Drive', (tester) async {
    await pump(tester, const BackupPlaces(offerGoogleDrive: false));
    expect(find.byKey(const ValueKey('backup-add-webdav')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-add-google-drive')), findsNothing);
  });
}
