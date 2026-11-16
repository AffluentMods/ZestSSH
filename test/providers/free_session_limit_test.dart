import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart' show SSHSocket;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The free tier (4.0): 5 sessions open at once on a computer, 3 on a phone
/// (tablets and Chromebooks count as phones), and a remote screen's tab takes
/// one of them as a terminal does. Its carrier SSH host is inside the screen's
/// session and takes none.
///
/// Every host here is dialled and never answers, so each session stays
/// connecting, which holds its place as a connected one does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late List<String> dialled;
  var started = false;

  Future<void> start({required bool isPro}) async {
    started = true;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(isPro)),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(activeSessionsProvider.notifier).debugScreenNative = FakeScreenNative();
    dialled = [];
    SshService.debugOpenSocket = (host, port, timeout) {
      dialled.add('$host:$port');
      return Completer<SSHSocket>().future;
    };
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    SshService.debugOpenSocket = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);

  final at = DateTime(2026, 11, 8);
  Future<void> host(String id, String label, String address,
      {String protocol = 'ssh', int port = 22, String? via}) async {
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: address,
          port: Value(port),
          protocol: Value(protocol),
          connectViaId: Value(via),
          createdAt: at,
          updatedAt: at,
        ));
  }

  Future<String?> open(String id) async => sessions().startSession((await tree.connectionsDao.getById(id))!);

  /// The terminals web-1 to web-6, the carrier gw, and the screens desk and
  /// lab behind it.
  Future<void> hosts() async {
    for (var i = 1; i <= 6; i++) {
      await host('h$i', 'web-$i', 'web-$i.example.com');
    }
    await host('h-gw', 'gw', 'gw.example.com');
    await host('s-desk', 'desk', 'localhost', protocol: 'vnc', port: 5900, via: 'h-gw');
    await host('s-lab', 'lab', 'localhost', protocol: 'vnc', port: 5901, via: 'h-gw');
  }

  test('5 on a computer and 3 on a phone, one line to change', () {
    expect(freeSessionLimitDesktop, 5);
    expect(freeSessionLimitMobile, 3);
    expect(freeSessionLimit, isDesktopPlatform ? 5 : 3);
  });

  test('a free account: terminals and one screen up to the limit, the screen counted once (its carrier is not '
      'a session), and the next terminal or screen refused', () async {
    await start(isPro: false);
    await hosts();
    final opened = <String>[];
    for (var i = 1; i < freeSessionLimit; i++) {
      opened.add((await open('h$i'))!);
    }
    final desk = (await open('s-desk'))!;
    opened.add(desk);
    expect(sessions().isScreen(desk), isTrue);
    expect(sessions().occupiedSessionSlots, freeSessionLimit);
    if (isDesktopPlatform) expect(opened, hasLength(5), reason: '4 terminals and 1 screen');

    expect(await open('h6'), isNull, reason: 'the 6th on a computer, the 4th on a phone');
    expect(await open('s-lab'), isNull, reason: 'a screen is refused as a terminal is');
    expect(sessions().occupiedSessionSlots, freeSessionLimit);
    expect(dialled, isNot(contains('web-6.example.com:22')));

    // Closing one frees its place at once.
    await sessions().endSession(desk);
    expect(await open('h6'), isNotNull);
    for (final id in container.read(activeSessionsProvider).keys.toList()) {
      await sessions().endSession(id);
    }
  });

  test('Squeezed: no limit, screens included', () async {
    await start(isPro: true);
    await hosts();
    for (var i = 1; i <= 6; i++) {
      expect(await open('h$i'), isNotNull);
    }
    expect(await open('s-desk'), isNotNull);
    expect(await open('s-lab'), isNotNull);
    expect(sessions().occupiedSessionSlots, 8);
    for (final id in container.read(activeSessionsProvider).keys.toList()) {
      await sessions().endSession(id);
    }
  });
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
