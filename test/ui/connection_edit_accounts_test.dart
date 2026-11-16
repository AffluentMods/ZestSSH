import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// The host editor and a host's other accounts (3.0, accounts per host):
/// below the identity a host is signed in to with by default, the other
/// identities it can be signed in to with, in their order, each with "Use by
/// default" and Remove, and "Add an account". What the form says is what is
/// saved; for a host that is there and for a new one.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, {String? connectionId, List<String> others = const []}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 15);
    await tester.runAsync(() async {
      for (final (id, user, method) in [
        ('alex', 'alex', 'publicKey'),
        ('root', 'root', 'password'),
        ('deploy', 'deploy', 'publicKey'),
      ]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: '$user key',
              username: user,
              authMethod: method,
              createdAt: now,
            ));
      }
      if (connectionId != null) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: connectionId,
              label: 'web-01',
              host: '192.168.10.21',
              identityId: const Value('alex'),
              createdAt: now,
              updatedAt: now,
            ));
        await db.hostAccountsDao.setOtherAccounts(connectionId, others);
      }
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ConnectionEditScreen(connectionId: connectionId, inDialog: true, onClose: () {})),
      ),
    ));
    await settle(tester);
  }

  /// The other accounts as the form shows them, in order.
  List<String> shown(WidgetTester tester) => [
        for (final w in tester.widgetList(find.descendant(
            of: find.byKey(const ValueKey('host-accounts')),
            matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
                RegExp(r'^host-account-[a-z]+$').hasMatch((w.key! as ValueKey<String>).value)))))
          (w.key! as ValueKey<String>).value.substring('host-account-'.length),
      ];

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await settle(tester);
  }

  Future<void> add(WidgetTester tester, String id) async {
    await tap(tester, find.byKey(const ValueKey('host-accounts-add')));
    await tap(tester, find.byKey(ValueKey('host-accounts-add-$id')).last);
  }

  /// [label] picked from the identity's menu (the other accounts under the
  /// field show the same names, so it is found in the menu).
  Future<void> pickDefault(WidgetTester tester, String label) async {
    await tap(tester, find.byType(ZestSelect<String?>).first);
    await tap(tester, find.descendant(of: find.byType(MenuItemButton), matching: find.text(label)));
  }

  Future<void> save(WidgetTester tester) async {
    await tap(tester, find.text(en.connectionSaveChanges));
  }

  Future<(String?, List<String>)> saved(String id) async {
    final host = await (db.select(db.connections)..where((c) => c.id.equals(id))).getSingle();
    return (host.identityId, await db.hostAccountsDao.otherAccountsOf(id));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets('the other accounts are shown below the identity; added, used by default and removed, they are saved so',
      (tester) async {
    await pump(tester, connectionId: 'c1', others: ['root']);
    expect(shown(tester), ['root']);
    // They continue the Identity field: no section of their own.
    expect(find.text('Other accounts'), findsNothing);
    expect(find.text(en.hostAccountsHelp), findsOneWidget);

    await add(tester, 'deploy');
    expect(shown(tester), ['root', 'deploy']);
    // Root by default: alex, the default until now, takes its place.
    await tap(tester, find.byKey(const ValueKey('host-account-default-root')));
    expect(shown(tester), ['alex', 'deploy']);
    await tap(tester, find.byKey(const ValueKey('host-account-remove-deploy')));
    expect(shown(tester), ['alex']);
    await save(tester);
    final (defaultId, others) = (await tester.runAsync(() => saved('c1')))!;
    expect(defaultId, 'root');
    expect(others, ['alex']);
    await finish(tester);
  });

  testWidgets('an identity is offered once: what the host has already is not in Add an account', (tester) async {
    await pump(tester, connectionId: 'c1', others: ['root']);
    await tap(tester, find.byKey(const ValueKey('host-accounts-add')));
    expect(find.byKey(const ValueKey('host-accounts-add-deploy')), findsWidgets);
    expect(find.byKey(const ValueKey('host-accounts-add-root')), findsNothing);
    expect(find.byKey(const ValueKey('host-accounts-add-alex')), findsNothing);
    await finish(tester);
  });

  // Adding another key had no way to make one.
  testWidgets('Add another key offers Create new key, after the keys there are to pick', (tester) async {
    await pump(tester, connectionId: 'c1');
    await tap(tester, find.byKey(const ValueKey('host-accounts-add')));
    expect(find.byKey(const ValueKey('host-accounts-add-root')), findsWidgets);
    expect(find.byKey(const ValueKey('host-accounts-create')), findsOneWidget);
    expect(find.text(en.connectionCreateNewIdentity), findsWidgets);
    final keyTop = tester.getTopLeft(find.byKey(const ValueKey('host-accounts-add-deploy')).last).dy;
    final createTop = tester.getTopLeft(find.byKey(const ValueKey('host-accounts-create'))).dy;
    expect(createTop, greaterThan(keyTop), reason: 'Create new key comes after the keys');
    await finish(tester);
  });

  testWidgets('with every key already the host\'s, Add another key is still there, with only Create new key', (tester) async {
    await pump(tester, connectionId: 'c1', others: ['root', 'deploy']);
    expect(find.byKey(const ValueKey('host-accounts-add')), findsOneWidget,
        reason: 'it was hidden when no other key was left to pick');
    await tap(tester, find.byKey(const ValueKey('host-accounts-add')));
    expect(find.byKey(const ValueKey('host-accounts-create')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('host-accounts-add-')), findsNothing);
    await finish(tester);
  });

  testWidgets('the default chosen from the list leaves the other accounts; none chosen, the first takes its place',
      (tester) async {
    await pump(tester, connectionId: 'c1', others: ['root', 'deploy']);
    await pickDefault(tester, 'root key (root)');
    expect(shown(tester), ['deploy']);
    await pickDefault(tester, en.none);
    expect(shown(tester), isEmpty, reason: 'deploy is the default now');
    await save(tester);
    final (defaultId, others) = (await tester.runAsync(() => saved('c1')))!;
    expect(defaultId, 'deploy');
    expect(others, isEmpty);
    await finish(tester);
  });

  testWidgets('a host without other accounts shows only Add an account; one without an identity, nothing', (tester) async {
    await pump(tester, connectionId: 'c1');
    expect(shown(tester), isEmpty);
    expect(find.byKey(const ValueKey('host-accounts-add')), findsOneWidget);
    await pickDefault(tester, en.none);
    expect(find.byKey(const ValueKey('host-accounts')), findsNothing);
    await finish(tester);
  });

  testWidgets('a new host is saved with its other accounts', (tester) async {
    await pump(tester);
    await tester.enterText(find.widgetWithText(TextField, en.connectionNicknameHint), 'web-03');
    await tester.enterText(find.widgetWithText(TextField, en.phoneUiFormAddressHint), '192.168.10.23');
    await settle(tester);
    await pickDefault(tester, 'alex key (alex)');
    await add(tester, 'root');
    await tap(tester, find.text(en.connectionSaveConnection));
    final id = (await tester.runAsync(
        () async => (await (db.select(db.connections)..where((c) => c.label.equals('web-03'))).getSingle()).id))!;
    final (defaultId, others) = (await tester.runAsync(() => saved(id)))!;
    expect(defaultId, 'alex');
    expect(others, ['root']);
    await finish(tester);
  });
}
