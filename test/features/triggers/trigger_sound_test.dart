// A trigger's "Play a sound" plays on a phone and a tablet (found 16 October
// 2026 while comparing the five versions). It played the system's alert
// sound, which Flutter plays on computers alone: offered on a phone, it played
// nothing there. Now a phone or a tablet posts a notification of the system,
// with the sound the person's settings give it, naming the trigger and not
// the line that matched it; a computer plays the alert sound as before. The
// app's notice of a match said "Matched:" in English, and Android named the
// app's notification channels in English, whatever the language.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/triggers/widgets/trigger_edit_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/fake_notifications_plugin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final de = lookupAppLocalizations(const Locale('de'));
  final en = lookupAppLocalizations(const Locale('en'));

  late ProviderContainer container;
  late List<(String, String)> shown;
  late List<MethodCall> platformCalls;

  setUp(() async {
    L10nGlobal.update(de);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    shown = [];
    NotificationService.debugShown = (title, body) => shown.add((title, body));
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    debugTriggerSoundOnComputer = null;
    NotificationService.debugShown = null;
    NotificationService.debugShownChannel = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    L10nGlobal.update(en);
  });

  Future<TriggerRuntime> runtimeWith(List<({String name, String pattern, bool sound})> rules) async {
    final crud = container.read(triggerCrudProvider);
    for (final r in rules) {
      await crud.create(name: r.name, pattern: r.pattern, playSound: r.sound);
    }
    final runtime = container.read(triggerRuntimeProvider);
    await pumpEventQueue();
    return runtime;
  }

  List<MethodCall> alertSounds() => [
        for (final c in platformCalls)
          if (c.method == 'SystemSound.play' && c.arguments == 'SystemSoundType.alert') c,
      ];

  test('on a phone: a notification of the system, naming the trigger and not the line', () async {
    debugTriggerSoundOnComputer = false;
    final rtl = String.fromCharCode(0x202E);
    final runtime = await runtimeWith([
      (name: 'Build${rtl}deliaf', pattern: 'error', sound: true),
      (name: 'Quiet', pattern: 'warning', sound: false),
    ]);

    runtime.processOutput('s1', null, 'make: *** [all] error 2\n');
    await pumpEventQueue();
    expect(shown, [('Builddeliaf', de.trgPhoneSoundBody)], reason: "the trigger's name, cleaned; no word of the line");
    expect(NotificationService.debugShownChannel, 'zestssh_triggers', reason: 'a channel of its own, to silence alone');
    expect(alertSounds(), isEmpty, reason: 'no alert sound to play on a phone');
    // The app's own notice says what matched, in the person's language.
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.body, de.trgMatchedBody('error'));

    // A trigger that plays no sound posts nothing of the system.
    runtime.processOutput('s1', null, 'a warning\n');
    await pumpEventQueue();
    expect(shown, hasLength(1));
    expect(container.read(notificationCenterProvider).history.first.body, de.trgMatchedBody('warning'));
  });

  test("on a computer: the system's alert sound, and no notification of the system", () async {
    debugTriggerSoundOnComputer = true;
    final runtime = await runtimeWith([
      (name: 'Build failed', pattern: 'error', sound: true),
      (name: 'Quiet', pattern: 'warning', sound: false),
    ]);

    runtime.processOutput('s1', null, 'make: *** [all] error 2\n');
    await pumpEventQueue();
    expect(alertSounds(), hasLength(1));
    expect(shown, isEmpty);

    runtime.processOutput('s1', null, 'a warning\n');
    await pumpEventQueue();
    expect(alertSounds(), hasLength(1), reason: 'a trigger that plays no sound plays none');
    expect(shown, isEmpty);
  });

  test("on a computer whose person turned on system notifications (4.0): the alert sound, and the system's "
      'notification too while the window is not in front', () async {
    debugTriggerSoundOnComputer = true;
    var front = false;
    await computerWithSystemNotices(inFront: () => front);
    addTearDown(NotificationService.debugReset);
    NotificationService.debugShown = (title, body) => shown.add((title, body));
    final runtime = await runtimeWith([
      (name: 'Build failed', pattern: 'error', sound: true),
      (name: 'Quiet', pattern: 'warning', sound: false),
    ]);
    runtime.processOutput('s1', null, 'make: *** [all] error 2\n');
    await pumpEventQueue();
    expect(alertSounds(), hasLength(1));
    expect(shown, [('Build failed', de.trgPhoneSoundBody)], reason: 'named, and no word of the line');

    runtime.processOutput('s1', null, 'a warning\n');
    await pumpEventQueue();
    expect(shown, hasLength(1), reason: 'an alert that plays no sound is the window\'s alone, as on a phone');

    front = true;
    runtime.processOutput('s1', null, 'error again\n');
    await pumpEventQueue();
    expect(alertSounds(), hasLength(2));
    expect(shown, hasLength(1), reason: 'the window is in front: its notice is in sight');
  });

  test("Android's channels are named in the person's language", () {
    final names = {
      for (final id in NotificationService.channelIds)
        id: (NotificationService.channelOf(id).name, NotificationService.channelOf(id).description),
    };
    expect(names, {
      'zestssh_connections': (de.notifyChannelConnections, de.notifyChannelConnectionsDesc),
      'zestssh_support': (de.notifyChannelSupport, de.notifyChannelSupportDesc),
      'zestssh_triggers': (de.notifyChannelTriggers, de.notifyChannelTriggersDesc),
    });
  });

  for (final onComputer in [false, true]) {
    testWidgets(
        onComputer
            ? 'the editor of a computer says nothing more under Play a sound'
            : 'the editor of a phone says under Play a sound that it comes with a notification', (tester) async {
      debugTriggerSoundOnComputer = onComputer;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTriggerEditDialog(context: context, connections: const []),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(de.trgPlaySound), findsOneWidget);
      expect(find.text(de.trgPlaySoundPhoneHint), onComputer ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('Applies to masks host names and addresses in recording mode, as everywhere a host is named', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 30);
    late List<Connection> hosts;
    await tester.runAsync(() async {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('c1'),
        label: const Value('prod-database-01'),
        host: const Value('192.0.2.10'),
        port: const Value(22),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('c2'),
        label: const Value('to be left out'),
        host: const Value('build.example.com'),
        port: const Value(22),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      final rows = await db.select(db.connections).get();
      // One with no name of its own goes by its address.
      hosts = [rows.first, rows.last.copyWith(label: '')];
    });
    // (Read first: the mode's provider sets the redactor as it starts.)
    container.read(recordingModeProvider);
    container.read(recordingRedactLevelProvider);
    Redactor.instance.enabled = true;
    addTearDown(() => Redactor.instance.enabled = false);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTriggerEditDialog(context: context, connections: hosts),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final select = find.byType(ZestSelect<String?>);
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(find.text('prod-database-01'), findsNothing);
    expect(find.text('build.example.com'), findsNothing);
    final items = tester.widget<ZestSelect<String?>>(select).items;
    expect(items, hasLength(3), reason: 'all hosts, and the two');
    expect(items[1].label, Redactable.host('prod-database-01').display);
    expect(items[2].label, Redactable.address('build.example.com').display);
    expect(items[1].value, 'c1', reason: 'the value stays the id');
    Redactor.instance.enabled = false;
    await tester.pumpAndSettle();
  });
}
