import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/network_editor_page.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _Repo extends Fake implements NetworkRepository {
  Object? error;
  final updated = <Network>[];
  final deleted = <String>[];

  @override
  Future<void> create(Network network) => update(network);

  @override
  Future<void> update(Network network) async {
    if (error != null) throw error!;
    updated.add(network);
  }

  @override
  Future<void> delete(String id) async {
    if (error != null) throw error!;
    deleted.add(id);
  }
}

/// A network that could not be saved or deleted (3.0):
/// both said "Save failed:" or "Delete failed:" in English with the raw error
/// glued on, and the phone editor asked before deleting in a plain dialog.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late _Repo repo;
  var closed = 0;

  const office = Network(
    id: 'office',
    name: 'Office',
    color: GroupColor.gray,
    icon: LucideIcons.wifi,
    triggers: [SubnetTrigger('10.50.0.0/24')],
    isFallback: false,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repo = _Repo();
    closed = 0;
  });

  Future<ProviderContainer> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        networkRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: NetworkEditorPage(network: office, onClose: () => closed++)),
      ),
    ));
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(NetworkEditorPage)));
  }

  Finder inDialog(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('a save that fails says so in the app\'s words, with what was thrown to copy', (tester) async {
    repo.error = const FileSystemException('database is locked');
    final c = await open(tester);
    await tester.tap(find.text(en.networkEditorSave));
    await tester.pump();
    await tester.pump();
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.networkNotSaved);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('database is locked'));
    expect(closed, 0, reason: 'still open, to try again');
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('one that works closes it', (tester) async {
    await open(tester);
    await tester.tap(find.text(en.networkEditorSave));
    await tester.pump();
    await tester.pump();
    expect(repo.updated.single.id, 'office');
    expect(closed, 1);
  });

  testWidgets('deleting asks in the app\'s own dialog, and Cancel deletes nothing', (tester) async {
    final c = await open(tester);
    await tester.tap(find.text(en.networkEditorDelete));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inDialog('Office'), findsOneWidget);
    expect(inDialog(en.networksDeleteConfirm('Office')), findsOneWidget);
    await tester.tap(inDialog(en.networkEditorCancel));
    await tester.pumpAndSettle();
    expect(repo.deleted, isEmpty);
    expect(closed, 0);
    expect(c.read(notificationCenterProvider).history, isEmpty);

    // Closed without an answer (Back, or a tap beside it): nothing is deleted.
    await tester.tap(find.text(en.networkEditorDelete));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(ZestConfirmDialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(repo.deleted, isEmpty);
    expect(closed, 0);
  });

  testWidgets('a delete that fails says so, with what was thrown; one that works closes it', (tester) async {
    repo.error = const FileSystemException('database is locked');
    final c = await open(tester);
    await tester.tap(find.text(en.networkEditorDelete));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(en.networksDelete));
    await tester.pumpAndSettle();
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.networkNotDeleted);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('database is locked'));
    expect(closed, 0);

    repo.error = null;
    await tester.tap(find.text(en.networkEditorDelete));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(en.networksDelete));
    await tester.pumpAndSettle();
    expect(repo.deleted, ['office']);
    expect(closed, 1);
    await tester.pump(const Duration(seconds: 8));
  });

  test('a computer\'s networks screen says them the same way', () {
    final source = File('lib/features/networks/pages/networks_screen.dart').readAsStringSync();
    expect(source, contains(r"showTopSnackBar(context, l10n.networkNotSaved, isError: true, details: '$e');"));
    expect(source, contains(r"showTopSnackBar(context, l10n.networkNotDeleted, isError: true, details: '$e');"));
    for (final rel in ['lib/features/networks/pages/networks_screen.dart', 'lib/features/networks/pages/network_editor_page.dart']) {
      final text = File(rel).readAsStringSync();
      expect(text, isNot(contains('Save failed:')), reason: rel);
      expect(text, isNot(contains('Delete failed:')), reason: rel);
    }
  });

  test('every language says them its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.networkNotSaved, isNot(en.networkNotSaved), reason: '$locale');
      expect(t.networkNotDeleted, isNot(en.networkNotDeleted), reason: '$locale');
      expect(t.networkNotSaved, isNot(t.networkNotDeleted), reason: '$locale');
    }
  });
}
