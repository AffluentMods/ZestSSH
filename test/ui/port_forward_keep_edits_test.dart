import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_drafts.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_close_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Two problems of the Port Forwarding editor:
/// switching between Simple and Advanced said what was typed would be
/// lost, and going to a terminal and back lost it. Now a switch carries the
/// kind and the ports across and asks only where Advanced holds what Simple
/// cannot show, naming it; and unsaved edits are kept, in memory only, while
/// the page is away. (All names and addresses made up.)
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  PortForwardRule rule({
    String id = 'pf-db',
    String type = 'local',
    String bindAddress = '127.0.0.1',
    int bindPort = 15432,
    String remoteHost = 'localhost',
    int remotePort = 5432,
    String? sshFlags,
  }) => PortForwardRule(
    id: id,
    connectionId: 'mon',
    type: type,
    bindAddress: bindAddress,
    bindPort: bindPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
    autoStart: false,
    reconnect: true,
    exitOnFailure: true,
    gatewayPorts: false,
    sshFlags: sshFlags,
    label: 'Database',
    createdAt: DateTime(2026, 10, 1),
  );

  group('switching between Simple and Advanced', () {
    test(
      'Simple to Advanced carries the kind and both ports, and is no edit',
      () {
        final c = PortForwardEditController()..bind(null, connectionId: 'mon');
        addTearDown(c.dispose);
        c.forwardType = PfForwardType.remote;
        c.simpleBindPortController.text = '3000';
        c.simpleRemotePortController.text = '8080';
        final simple = c.buildCompanion().companion!;

        c.setMode(PfEditorMode.advanced);
        expect(c.isDirty, isFalse, reason: 'a switch is not an edit');
        expect(c.advancedType, PfForwardType.remote);
        expect(c.advSourcePortController.text, '3000');
        expect(c.advDestPortController.text, '8080');
        final advanced = c.buildCompanion().companion!;
        expect(
          (
            advanced.type.value,
            advanced.bindPort.value,
            advanced.remotePort.value,
            advanced.remoteHost.value,
          ),
          (
            simple.type.value,
            simple.bindPort.value,
            simple.remotePort.value,
            simple.remoteHost.value,
          ),
          reason: 'the same rule is saved from either',
        );
      },
    );

    test(
      'Advanced to Simple carries them back, and a rule Simple can show needs no question',
      () {
        final c = PortForwardEditController()..bind(rule());
        addTearDown(c.dispose);
        expect(c.mode, PfEditorMode.advanced);
        c.advSourcePortController.text = '15433';
        c.markDirty();
        expect(c.simpleCannotShow, isEmpty);

        c.setMode(PfEditorMode.simple);
        expect(c.forwardType, PfForwardType.local);
        expect(c.simpleBindPortController.text, '15433');
        expect(c.simpleRemotePortController.text, '5432');
        expect(
          c.isDirty,
          isTrue,
          reason: 'still the edit it was, no more and no less',
        );
      },
    );

    test(
      'a dynamic forward carries its one port and leaves the other as it was',
      () {
        final c = PortForwardEditController()..bind(null);
        addTearDown(c.dispose);
        c.setMode(PfEditorMode.advanced);
        c.advDestPortController.text = '3306';
        c.forwardType = PfForwardType.dynamic;
        c.simpleBindPortController.text = '1080';
        c.setMode(PfEditorMode.simple);
        c.forwardType = PfForwardType.dynamic;
        c.simpleBindPortController.text = '1081';
        c.setMode(PfEditorMode.advanced);
        expect(c.advancedType, PfForwardType.dynamic);
        expect(c.advSourcePortController.text, '1081');
        expect(c.advDestPortController.text, '3306');
      },
    );

    test(
      'what Simple cannot show: a source host not this device, a destination not localhost, flags of its own',
      () {
        Set<PfSimpleCannotShow> of(PortForwardRule r) {
          final c = PortForwardEditController()..bind(r);
          final found = c.simpleCannotShow;
          c.dispose();
          return found;
        }

        expect(of(rule()), isEmpty);
        expect(
          of(
            rule(
              bindAddress: 'localhost',
              remoteHost: 'LOCALHOST',
              sshFlags: '-f  -N',
            ),
          ),
          isEmpty,
        );
        expect(of(rule(bindAddress: '::1', sshFlags: '')), isEmpty);
        expect(of(rule(bindAddress: '0.0.0.0')), {
          PfSimpleCannotShow.sourceHost,
        });
        expect(of(rule(remoteHost: 'db.internal')), {
          PfSimpleCannotShow.destinationHost,
        });
        expect(
          of(rule(remoteHost: '127.0.0.1')),
          {PfSimpleCannotShow.destinationHost},
          reason:
              'Simple saves the word localhost, which the server may take otherwise',
        );
        expect(of(rule(sshFlags: '-N -f -v')), {PfSimpleCannotShow.flags});
        expect(
          of(
            rule(
              type: 'dynamic',
              remoteHost: '',
              remotePort: 0,
              bindAddress: '192.168.1.5',
            ),
          ),
          {PfSimpleCannotShow.sourceHost},
        );
      },
    );

    test(
      'Advanced keeps its hosts and flags through Simple; a save from Simple makes them what was saved',
      () {
        final c = PortForwardEditController()
          ..bind(rule(remoteHost: 'db.internal', sshFlags: '-N -f -v'));
        addTearDown(c.dispose);
        c.setMode(PfEditorMode.simple);
        c.simpleRemotePortController.text = '5433';
        c.markDirty();
        c.setMode(PfEditorMode.advanced);
        expect(
          c.advDestHostController.text,
          'db.internal',
          reason: 'nothing was saved from Simple',
        );
        expect(c.advFlagsController.text, '-N -f -v');
        expect(
          c.advDestPortController.text,
          '5433',
          reason: 'what was typed in Simple came across',
        );

        c.setMode(PfEditorMode.simple);
        final saved = c.buildCompanion().companion!;
        expect(saved.remoteHost.value, 'localhost');
        c.markSaved(rule(remotePort: 5433));
        expect(c.advDestHostController.text, 'localhost');
        expect(c.advFlagsController.text, kPfDefaultFlags);
        expect(c.simpleCannotShow, isEmpty);
      },
    );
  });

  test('a draft holds everything typed, and comes back as unsaved', () {
    final a = PortForwardEditController()
      ..bind(rule(remoteHost: 'db.internal'));
    addTearDown(a.dispose);
    a.nameController.text = 'Primary database';
    a.gatewayPorts = true;
    a.advDestPortController.text = '5434';
    a.markDirty();
    final b = PortForwardEditController()..bind(null);
    addTearDown(b.dispose);
    b.restore(a.snapshot());
    expect(b.isDirty, isTrue);
    expect(b.original?.id, 'pf-db');
    expect(b.mode, PfEditorMode.advanced);
    expect(b.nameController.text, 'Primary database');
    expect(b.gatewayPorts, isTrue);
    expect(b.advDestHostController.text, 'db.internal');
    expect(b.advDestPortController.text, '5434');
  });

  group('the page', () {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    late AppDatabase db;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// The page, and a switch standing for the shell showing a terminal in
    /// its place (the page goes, as it does there).
    Future<(ProviderContainer, ValueNotifier<bool>)> open(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final at = DateTime(2026, 10, 1);
        for (final (id, label, address) in [
          ('mon', 'monitoring', '192.168.10.60'),
          ('api', 'web-01', '192.168.10.21'),
        ]) {
          await db
              .into(db.connections)
              .insert(
                ConnectionsCompanion.insert(
                  id: id,
                  label: label,
                  host: address,
                  createdAt: at,
                  updatedAt: at,
                ),
              );
        }
        await db
            .into(db.portForwardRules)
            .insert(
              PortForwardRulesCompanion.insert(
                id: 'pf-db',
                connectionId: 'mon',
                type: 'local',
                bindPort: 15432,
                remoteHost: 'db.internal',
                remotePort: 5432,
                label: const Value('Database'),
                createdAt: at,
              ),
            );
        await db
            .into(db.portForwardRules)
            .insert(
              PortForwardRulesCompanion.insert(
                id: 'pf-prom',
                connectionId: 'mon',
                type: 'local',
                bindPort: 9090,
                remoteHost: 'localhost',
                remotePort: 9090,
                label: const Value('Prometheus'),
                createdAt: at,
              ),
            );
      });
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          activeForwardIdsProvider.overrideWith((ref) => <String>{}),
        ],
      );
      addTearDown(container.dispose);
      final pageShown = ValueNotifier(true);
      addTearDown(pageShown.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: pageShown,
                builder: (_, shown, _) => shown
                    ? const PortForwardListView()
                    : const Text('a terminal'),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      return (container, pageShown);
    }

    Finder field(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(EditableText),
    );
    String textOf(WidgetTester tester, String key) =>
        tester.widget<EditableText>(field(key)).controller.text;

    /// Whether anything in the preferences holds [typed] (or is a draft).
    bool prefsHold(String typed) => prefs.getKeys().any(
      (k) =>
          k.toLowerCase().contains('draft') ||
          '${prefs.get(k)}'.contains(typed),
    );
    bool saveOn(WidgetTester tester) =>
        tester
            .widget<ZestButton>(find.byKey(const ValueKey('pf-save')))
            .onPressed !=
        null;

    Future<void> fillRemote(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('pf-intent-remote')));
      await settle(tester);
      await tester.enterText(field('pf-name'), 'Dev database');
      await tester.tap(find.text(en.zestPfChooseConnection));
      await settle(tester);
      await tester.tap(find.text('web-01').last);
      await settle(tester);
      await tester.enterText(field('pf-port-here'), '3000');
      await tester.enterText(field('pf-port-server'), '8080');
      await settle(tester);
    }

    Future<void> awayAndBack(
      WidgetTester tester,
      ValueNotifier<bool> pageShown,
    ) async {
      pageShown.value = false;
      await settle(tester);
      expect(
        find.byType(PortForwardListView),
        findsNothing,
        reason: 'the page went, as it does for a terminal',
      );
      pageShown.value = true;
      await settle(tester);
    }

    testWidgets(
      'Simple to Advanced and back with unsaved edits asks nothing and keeps them',
      (tester) async {
        await open(tester);
        await fillRemote(tester);
        await tester.tap(find.text(en.zestModeAdvanced));
        await settle(tester);
        expect(find.byType(ZestConfirmDialog), findsNothing);
        expect(find.text(en.zestDiscardTitle), findsNothing);
        expect(
          find.textContaining('-R 8080:localhost:3000'),
          findsWidgets,
          reason: 'the ports came across',
        );
        expect(saveOn(tester), isTrue);

        await tester.tap(find.text(en.zestModeSimple));
        await settle(tester);
        expect(find.byType(ZestConfirmDialog), findsNothing);
        expect(textOf(tester, 'pf-port-here'), '3000');
        expect(textOf(tester, 'pf-port-server'), '8080');
      },
    );

    testWidgets(
      'to Simple from a rule with its own destination host: asked first, naming it',
      (tester) async {
        await open(tester);
        await tester.tap(find.text('Database'));
        await settle(tester);
        await tester.tap(find.text(en.zestModeSimple));
        await settle(tester);
        expect(find.byType(ZestConfirmDialog), findsOneWidget);
        expect(find.text(en.pfToSimpleTitle), findsOneWidget);
        expect(find.text(en.pfToSimpleDestinationHost), findsOneWidget);
        expect(find.text(en.pfToSimpleSourceHost), findsNothing);
        expect(find.text(en.pfToSimpleFlags), findsNothing);

        await tester.tap(find.text(en.cancel).last);
        await settle(tester);
        expect(
          find.byKey(const ValueKey('pf-port-here')),
          findsNothing,
          reason: 'still in Advanced',
        );

        await tester.tap(find.text(en.zestModeSimple));
        await settle(tester);
        await tester.tap(find.text(en.pfToSimpleConfirm));
        await settle(tester);
        expect(textOf(tester, 'pf-port-here'), '15432');
        expect(textOf(tester, 'pf-port-server'), '5432');
        expect(saveOn(tester), isFalse, reason: 'a switch is no edit');
      },
    );

    testWidgets('a rule Simple can show switches with no question', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Prometheus'));
      await settle(tester);
      await tester.tap(find.text(en.zestModeSimple));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing);
      expect(textOf(tester, 'pf-port-here'), '9090');
    });

    testWidgets(
      'a new rule typed, a terminal, the page again: the form as it was, unsaved; Save leaves no draft',
      (tester) async {
        final (container, pageShown) = await open(tester);
        await fillRemote(tester);
        await awayAndBack(tester, pageShown);

        expect(textOf(tester, 'pf-name'), 'Dev database');
        expect(textOf(tester, 'pf-port-here'), '3000');
        expect(textOf(tester, 'pf-port-server'), '8080');
        expect(saveOn(tester), isTrue, reason: 'shown as unsaved');
        expect(
          prefsHold('Dev database'),
          isFalse,
          reason: 'kept in memory only',
        );

        await tester.tap(find.byKey(const ValueKey('pf-save')));
        await settle(tester);
        final rules = await tester.runAsync(
          () => db.portForwardRulesDao.getAll(),
        );
        expect(rules!.where((r) => r.label == 'Dev database'), hasLength(1));
        expect(container.read(portForwardDraftsProvider).isEmpty, isTrue);

        await awayAndBack(tester, pageShown);
        expect(saveOn(tester), isFalse, reason: 'nothing unsaved came back');
        expect(
          textOf(tester, 'pf-name'),
          isEmpty,
          reason:
              'with nothing unsaved the page opens on a new rule, as before',
        );
      },
    );

    testWidgets(
      'a saved rule edited, a terminal, the page again: that rule, with the edit, unsaved',
      (tester) async {
        final (_, pageShown) = await open(tester);
        await tester.tap(find.text('Prometheus'));
        await settle(tester);
        final name = find.descendant(
          of: find.byType(PortForwardListView),
          matching: find.byType(EditableText),
        );
        final nameField = name
            .evaluate()
            .map((e) => e.widget as EditableText)
            .firstWhere((w) => w.controller.text == 'Prometheus');
        await tester.enterText(find.byWidget(nameField), 'Prometheus (main)');
        await settle(tester);
        await awayAndBack(tester, pageShown);

        expect(find.text('Prometheus (main)'), findsWidgets);
        expect(saveOn(tester), isTrue);
        await tester.tap(find.byKey(const ValueKey('pf-save')));
        await settle(tester);
        final rules = await tester.runAsync(
          () => db.portForwardRulesDao.getAll(),
        );
        expect(
          rules!.singleWhere((r) => r.id == 'pf-prom').label,
          'Prometheus (main)',
        );
      },
    );

    testWidgets('Close and Discard leave no draft', (tester) async {
      final (container, pageShown) = await open(tester);
      await fillRemote(tester);
      await awayAndBack(tester, pageShown);
      await tester.tap(find.byType(ZestCloseButton));
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard));
      await settle(tester);
      expect(container.read(portForwardDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      expect(textOf(tester, 'pf-name'), isEmpty);
      expect(saveOn(tester), isFalse);
    });

    testWidgets('deleting the rule leaves no draft', (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Prometheus'));
      await settle(tester);
      await tester.tap(find.text(en.zestModeSimple));
      await settle(tester);
      await tester.enterText(field('pf-port-here'), '9091');
      await settle(tester);
      await awayAndBack(tester, pageShown);
      expect(textOf(tester, 'pf-port-here'), '9091');

      await tester.tap(find.byKey(const ValueKey('pf-delete')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ZestConfirmDialog),
          matching: find.text('Delete'),
        ),
      );
      await settle(tester);
      final rules = await tester.runAsync(
        () => db.portForwardRulesDao.getAll(),
      );
      expect(rules!.where((r) => r.id == 'pf-prom'), isEmpty);
      expect(container.read(portForwardDraftsProvider).isEmpty, isTrue);
      await awayAndBack(tester, pageShown);
      expect(saveOn(tester), isFalse);
    });

    testWidgets('a change of profile forgets the drafts, kept or on screen', (
      tester,
    ) async {
      final (container, pageShown) = await open(tester);
      await fillRemote(tester);
      pageShown.value = false;
      await settle(tester);
      expect(container.read(portForwardDraftsProvider).isEmpty, isFalse);

      refreshPersonState(container);
      await settle(tester);
      expect(container.read(portForwardDraftsProvider).isEmpty, isTrue);
      pageShown.value = true;
      await settle(tester);
      expect(textOf(tester, 'pf-name'), isEmpty);
      expect(saveOn(tester), isFalse);

      // On screen as the profile changes: the form goes, and nothing of it is
      // kept for the next profile when the page goes after.
      await fillRemote(tester);
      refreshPersonState(container);
      await settle(tester);
      expect(textOf(tester, 'pf-name'), isEmpty);
      pageShown.value = false;
      await settle(tester);
      expect(container.read(portForwardDraftsProvider).isEmpty, isTrue);
      expect(prefsHold('Dev database'), isFalse);
    });
  });
}
