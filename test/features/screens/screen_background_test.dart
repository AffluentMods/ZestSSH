// Remote screens in the background (4.0). iOS: the screens
// are given the time iOS grants, closed cleanly 5 s before it runs out, shown
// as paused in their place, and connected again when the app is back (a quick
// switch just resumes); they never count as sessions dropped in the
// background. Android: a connected screen keeps the foreground service, whose
// notification names its host. A fake lifecycle, a fake grace and a fake
// clock; the session over the fake engine, reached directly.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
// A test dependency of flutter_test's own.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/screens/session/screen_background.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/background_grace.dart';
import 'package:zestssh/services/foreground_service.dart';

class _Grace implements BackgroundGraceApi {
  _Grace(this.gives);

  /// What iOS grants (null: nothing).
  Duration? gives;
  int begun = 0;
  int ended = 0;
  VoidCallback? expire;

  @override
  Future<Duration?> begin({required VoidCallback onExpired}) async {
    begun++;
    expire = onExpired;
    return gives;
  }

  @override
  Future<void> end() async {
    ended++;
    expire = null;
  }
}

/// Screens by id, connected or closed in the background, as the keeper sees them.
class _Screens {
  final connected = <String>{};
  final parked = <String>{};
  final reconnected = <String>[];

  ScreenBackgroundKeeper keeper(_Grace grace, {bool ios = true}) => ScreenBackgroundKeeper(
        connectedScreens: () => connected,
        parkedScreens: () => parked,
        park: (id) async {
          connected.remove(id);
          parked.add(id);
        },
        reconnect: (id) {
          reconnected.add(id);
          parked.remove(id);
          connected.add(id);
        },
        grace: grace,
        closesInBackground: ios,
      );
}

void main() {
  group('the keeper (iOS rule)', () {
    test('away longer than the grace: closed 5 s before it runs out, the grace given back; on return connected '
        'again, and counted for the notice', () {
      fakeAsync((clock) {
        final grace = _Grace(const Duration(seconds: 30));
        final screens = _Screens()..connected.addAll({'s1', 's2'});
        final keeper = screens.keeper(grace);
        unawaited(keeper.hidden());
        clock.flushMicrotasks();
        expect(grace.begun, 1);
        clock.elapse(const Duration(seconds: 24));
        expect(screens.parked, isEmpty, reason: 'still inside the grace, less the margin');
        clock.elapse(const Duration(seconds: 1, milliseconds: 1));
        expect(screens.parked, {'s1', 's2'});
        expect(screens.connected, isEmpty);
        expect(grace.ended, 1);
        // Told twice (hidden, then paused): nothing more.
        unawaited(keeper.hidden());
        clock.flushMicrotasks();
        expect(grace.begun, 1);

        expect(keeper.resumed(), 2);
        expect(screens.reconnected, unorderedEquals(['s1', 's2']));
        expect(grace.ended, 1, reason: 'given back already');
        expect(keeper.resumed(), 0, reason: 'only once per return');
      });
    });

    test('a quick switch to another app and back: nothing closed, nothing connected again, the grace given back',
        () {
      fakeAsync((clock) {
        final grace = _Grace(const Duration(seconds: 30));
        final screens = _Screens()..connected.add('s1');
        final keeper = screens.keeper(grace);
        unawaited(keeper.hidden());
        clock.elapse(const Duration(seconds: 10));
        expect(keeper.resumed(), 0);
        expect(grace.ended, 1);
        clock.elapse(const Duration(minutes: 1));
        expect(screens.parked, isEmpty);
        expect(screens.connected, {'s1'});
        expect(screens.reconnected, isEmpty);
      });
    });

    test('back in front while the screens are being closed: the one in the middle of closing is connected again, '
        'and the rest are left open', () {
      fakeAsync((clock) {
        final grace = _Grace(const Duration(seconds: 30));
        final connected = <String>{'s1', 's2', 's3'};
        final parked = <String>{};
        final reconnected = <String>[];
        final closing = <String, Completer<void>>{};
        final keeper = ScreenBackgroundKeeper(
          connectedScreens: () => connected,
          parkedScreens: () => parked,
          // Closing a screen takes time (the screen, then its carrier SSH).
          park: (id) async {
            closing[id] = Completer<void>();
            await closing[id]!.future;
            connected.remove(id);
            parked.add(id);
          },
          reconnect: (id) {
            reconnected.add(id);
            parked.remove(id);
            connected.add(id);
          },
          grace: grace,
          closesInBackground: true,
        );
        unawaited(keeper.hidden());
        clock.elapse(const Duration(seconds: 26));
        expect(closing.keys, ['s1'], reason: 'the first is closing');
        // The person comes back before it has closed.
        expect(keeper.resumed(), 0, reason: 'none was paused yet');
        closing['s1']!.complete();
        clock.flushMicrotasks();
        expect(reconnected, ['s1'], reason: 'closed after the return: connected again, not left paused');
        expect(closing.keys, ['s1'], reason: 'the others are not closed in front of the person');
        expect(connected, {'s1', 's2', 's3'});
        expect(parked, isEmpty);
        expect(grace.ended, 1);
      });
    });

    test('iOS says the time is up before the timer: closed at once', () {
      fakeAsync((clock) {
        final grace = _Grace(const Duration(seconds: 30));
        final screens = _Screens()..connected.add('s1');
        final keeper = screens.keeper(grace);
        unawaited(keeper.hidden());
        clock.elapse(const Duration(seconds: 3));
        grace.expire!();
        clock.flushMicrotasks();
        expect(screens.parked, {'s1'});
        clock.elapse(const Duration(minutes: 1));
        expect(screens.reconnected, isEmpty, reason: 'nothing connects while the app is away');
      });
    });

    test('no grace given (or less than the margin): closed at once', () {
      fakeAsync((clock) {
        for (final gives in [null, const Duration(seconds: 4)]) {
          final grace = _Grace(gives);
          final screens = _Screens()..connected.add('s1');
          unawaited(screens.keeper(grace).hidden());
          clock.flushMicrotasks();
          expect(screens.parked, {'s1'}, reason: 'given $gives');
          expect(grace.ended, 1);
        }
      });
    });

    test('no screen open: no grace asked for; Android and computers (no closing in the background): nothing at all',
        () {
      fakeAsync((clock) {
        final none = _Grace(const Duration(seconds: 30));
        final keeper = _Screens().keeper(none);
        unawaited(keeper.hidden());
        clock.elapse(const Duration(minutes: 1));
        expect(none.begun, 0);
        expect(keeper.resumed(), 0);

        final grace = _Grace(const Duration(seconds: 30));
        final screens = _Screens()..connected.add('s1');
        final android = screens.keeper(grace, ios: false);
        unawaited(android.hidden());
        clock.elapse(const Duration(minutes: 5));
        expect(grace.begun, 0);
        expect(screens.parked, isEmpty);
        expect(screens.connected, {'s1'});
        expect(android.resumed(), 0);
      });
    });
  });

  test('the "sessions dropped in the background" snapshot leaves remote screens out', () {
    const connected = SessionState(status: SessionStatus.connected);
    final sessions = {
      'term': connected,
      'screen': connected,
      'gone': const SessionState(status: SessionStatus.disconnected),
    };
    expect(connectedBeforeBackground(sessions, isScreen: (id) => id == 'screen'), {'term'});
  });

  group('with the app\'s sessions', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late AppDatabase tree;
    late ProviderContainer container;
    late FakeScreenNative engine;
    late _Grace grace;
    late List<(String, Map<String, Object?>)> service;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      grace = _Grace(const Duration(seconds: 30));
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
        connectionResolverProvider.overrideWithValue(_AsSaved()),
        screenBackgroundProvider.overrideWith((ref) {
          final keeper = ScreenBackgroundKeeper(
            connectedScreens: () {
              final s = ref.read(activeSessionsProvider);
              return ref
                  .read(activeSessionsProvider.notifier)
                  .screenSessionIds
                  .where((id) => s[id]?.status == SessionStatus.connected);
            },
            parkedScreens: () => ref.read(activeSessionsProvider.notifier).parkedScreenIds,
            park: (id) => ref.read(activeSessionsProvider.notifier).parkScreen(id),
            reconnect: (id) => ref.read(activeSessionsProvider.notifier).reconnectNow(id),
            grace: grace,
            closesInBackground: true,
          );
          ref.onDispose(keeper.dispose);
          return keeper;
        }),
      ]);
      container.read(databaseSessionProvider.notifier).seed(tree);
      container.read(autoReconnectEnabledProvider.notifier).state = true;
      engine = FakeScreenNative()..onOpen = (s) => s.connect(name: 'desk', width: 1280, height: 800);
      final sessions = container.read(activeSessionsProvider.notifier);
      sessions.debugScreenNative = engine;
      sessions.debugShellFor = (c) => ScreenShellService(
            target: DirectTlsTarget(c.host, c.port),
            trust: _Trust(),
            native: engine,
            openDirect: (host, port) async =>
                ScreenChannel(StreamController<Uint8List>().stream, StreamController<List<int>>()),
          );
      ActiveSessionsNotifier.debugReconnectDelay = Duration.zero;
      service = [];
      ForegroundService.debugCalls = (method, args) => service.add((method, args));
      final at = DateTime(2026, 11, 8);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 's-desk',
            label: 'Demo desktop',
            host: 'desk.example.com',
            port: const Value(5901),
            protocol: const Value('vnc'),
            createdAt: at,
            updatedAt: at,
          ));
    });

    tearDown(() async {
      ForegroundService.debugCalls = null;
      ActiveSessionsNotifier.debugReconnectDelay = null;
      container.dispose();
      await tree.close();
    });

    ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
    SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

    Future<void> until(bool Function() check, String what) async {
      final clock = Stopwatch()..start();
      while (!check()) {
        if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<String> openDesk() async {
      final id = sessions().startSession((await tree.connectionsDao.getById('s-desk'))!)!;
      await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
      return id;
    }

    test('Android: a connected screen keeps the foreground service, and its notification names the screen\'s host',
        () async {
      final id = await openDesk();
      expect(sessions().isScreen(id), isTrue);
      final (method, args) = service.last;
      expect(method, 'startService');
      expect(args['count'], 1);
      expect(args['names'], ['Demo desktop']);
    });

    test('iOS: away past the grace, the screen is closed cleanly (its engine closed), kept in its place as paused, '
        'not dropped and not connected again while away; back, it connects again in its place', () async {
      final id = await openDesk();
      final first = engine.sessions.single;
      final keeper = container.read(screenBackgroundProvider);
      // Granted no more than the margin: closed at once (the timer's own
      // rule is the keeper's test above).
      grace.gives = const Duration(seconds: 5);
      await keeper.hidden();
      await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the screen to close');
      expect(first.closed, isTrue);
      expect(sessions().isParkedScreen(id), isTrue);
      expect(sessions().isScreen(id), isTrue, reason: 'still a screen, in its place');
      final parked = stateOf(id)!;
      expect(parked.dropped, isFalse, reason: 'closed by the app, not lost');
      expect(parked.isReconnecting, isFalse);
      expect(parked.connectionLog.last, contains('Closed while the app is in the background'));
      expect(grace.ended, 1);
      expect(service.last.$1, 'stopService', reason: 'nothing left for the service to keep');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.sessions, hasLength(1), reason: 'nothing connects while the app is away');

      expect(keeper.resumed(), 1);
      await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect again');
      expect(engine.sessions, hasLength(2));
      expect(sessions().isParkedScreen(id), isFalse);
    });

    test('iOS: back within the grace, the screen is still connected and nothing is connected again', () async {
      final id = await openDesk();
      final keeper = container.read(screenBackgroundProvider);
      await keeper.hidden();
      expect(grace.begun, 1);
      expect(keeper.resumed(), 0);
      expect(grace.ended, 1);
      expect(stateOf(id)!.status, SessionStatus.connected);
      expect(engine.sessions.single.closed, isFalse);
      expect(sessions().isParkedScreen(id), isFalse);
    });

    test('a paused screen that is closed (its tab) is no longer paused', () async {
      final id = await openDesk();
      await sessions().parkScreen(id);
      expect(sessions().isParkedScreen(id), isTrue);
      await sessions().endSession(id);
      expect(sessions().parkedScreenIds, isEmpty);
    });
  });
}

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;

  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => false;

  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
