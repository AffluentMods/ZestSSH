// Remote screens (4.0): "Open console" on a host imported from a Proxmox
// account opens the guest's console as a screen session of its own, through the account this
// device keeps (its token, its pinned certificate), with the console's password and no
// VeNCrypt; refused where the account is not here, and under the team rule that opens remote
// screens through an SSH host only. The Proxmox API is played (debugOpenConsole) and so is the
// engine.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_guest_of.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

final en = lookupAppLocalizations(const Locale('en'));

const _token = 'zestssh@pve!console=made-up-not-a-token';

CloudLink _link(String machineId, {CloudProvider provider = CloudProvider.proxmox, bool gone = false}) =>
    CloudLink(provider: provider, machineId: machineId, label: 'Lab', gone: gone);

void main() {
  group('which hosts offer it', () {
    test('a Proxmox VM or container a kept account imported; not a node, another provider, a gone one, or none',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      var n = 0;
      Future<Connection> host(String? cloudSource) async {
        final id = 'h${n++}';
        final at = DateTime(2026, 11, 17);
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: 'web-vm',
              host: '10.50.0.20',
              createdAt: at,
              updatedAt: at,
              cloudSource: Value(cloudSource),
            ));
        return (await db.connectionsDao.getById(id))!;
      }

      final g = proxmoxGuestOf(await host(_link('pve.example.test:8006/pve/100').encode()))!;
      expect((g.host, g.port, g.node, g.vmid), ('pve.example.test', 8006, 'pve', 100));
      expect(proxmoxGuestOf(await host(_link('pve.example.test:8006/node/pve').encode())), isNull, reason: 'a node');
      expect(proxmoxGuestOf(await host(_link('i-0abc', provider: CloudProvider.aws).encode())), isNull);
      expect(proxmoxGuestOf(await host(_link('pve.example.test:8006/pve/100', gone: true).encode())), isNull);
      expect(proxmoxGuestOf(await host(null)), isNull);
      expect(proxmoxGuestOf(await host('not a link')), isNull);
    });
  });

  group('the session', () {
    late AppDatabase tree;
    late ProviderContainer container;
    late FakeScreenNative engine;
    late List<({Uri base, String token, ProxmoxGuest guest, String? pin})> opened;
    late Object? refuseWith;

    Future<void> start({List<CloudAccount> accounts = const [], bool team = false}) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      L10nGlobal.update(en);
      tree = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team);
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro(true)),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
        connectionResolverProvider.overrideWithValue(_AsSaved()),
        cloudAccountStoreProvider.overrideWithValue(_Store(accounts)),
      ]);
      container.read(databaseSessionProvider.notifier).seed(tree);
      engine = FakeScreenNative();
      opened = [];
      refuseWith = null;
      final sessions = container.read(activeSessionsProvider.notifier)
        ..debugScreenNative = engine
        ..debugOpenConsole = ({required base, required token, required guest, pin}) async {
          opened.add((base: base, token: token, guest: guest, pin: pin));
          final refusal = refuseWith;
          if (refusal != null) throw refusal;
          final toEngine = StreamController<Uint8List>();
          addTearDown(toEngine.close);
          return ProxmoxConsole(
            channel: ScreenChannel(toEngine.stream, StreamController<List<int>>().sink),
            password: 'Ab3dE7gH',
            kind: 'qemu',
          );
        };
      addTearDown(() async {
        for (final id in sessions.state.keys.toList()) {
          await sessions.endSession(id);
        }
        container.dispose();
        await tree.close();
      });
    }

    Future<Connection> guestHost({String link = 'pve.example.test:8006/pve/100'}) async {
      final at = DateTime(2026, 11, 17);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-vm',
            label: 'web-vm',
            host: '10.50.0.20',
            createdAt: at,
            updatedAt: at,
            cloudSource: Value(_link(link).encode()),
          ));
      return (await tree.connectionsDao.getById('h-vm'))!;
    }

    const lab = CloudAccount(
      id: 'a1',
      provider: CloudProvider.proxmox,
      label: 'Lab',
      fields: {
        CloudField.url: 'https://pve.example.test:8006',
        CloudField.token: _token,
        CloudField.pin: 'AB:CD',
      },
    );

    Future<void> until(bool Function() check, String what) async {
      final clock = Stopwatch()..start();
      while (!check()) {
        if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
    SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

    test("opened through the kept account: its address, token and pin; the console's password, no VeNCrypt; a tab of "
        'its own, named as a console', () async {
      await start(accounts: [
        const CloudAccount(id: 'a0', provider: CloudProvider.proxmox, label: 'Other', fields: {
          CloudField.url: 'https://other.example.test:8006',
          CloudField.token: 'root@pam!x=another-made-up-token',
        }),
        lab,
      ]);
      engine.onOpen = (s) => s.connect(name: 'web-vm console');
      final host = await guestHost();
      final id = sessions().startConsole(host)!;
      await until(() => stateOf(id)?.status == SessionStatus.connected, 'the console to connect');
      expect(opened.single.base, Uri.parse('https://pve.example.test:8006'));
      expect(opened.single.token, _token, reason: 'the account of that cluster, not the other');
      expect(opened.single.pin, 'AB:CD');
      expect((opened.single.guest.node, opened.single.guest.vmid), ('pve', 100));
      final request = engine.sessions.single.request;
      expect(request['kind'], 'vnc');
      expect(request['password'], 'Ab3dE7gH');
      expect(request['require_tls'], isFalse, reason: 'the VNC is inside the API\'s TLS');
      expect(sessions().isConsole(id), isTrue);
      expect(sessions().isScreen(id), isTrue);
      expect(stateOf(id)!.connectionLabel, en.consoleTabLabel('web-vm'));
      expect(stateOf(id)!.connectionLog.join('\n'), isNot(contains(_token)));
      expect(stateOf(id)!.connectionLog.join('\n'), isNot(contains('Ab3dE7gH')));
      // A second console of the same guest is a tab of its own.
      final again = sessions().startConsole(host)!;
      expect(again, isNot(id));
    });

    test("a console starts as a new host does: on a computer this device's clipboard goes to the guest only when its "
        'person pastes into the picture (it went whenever the picture took the keyboard)', () async {
      await start(accounts: [lab]);
      engine.onOpen = (s) => s.connect(name: 'web-vm console');
      final id = sessions().startConsole(await guestHost())!;
      await until(() => stateOf(id)?.status == SessionStatus.connected, 'the console to connect');
      final shell = stateOf(id)!.session!.shell as ScreenShellService;
      expect(shell.options.clipboardOnPaste, isTrue);
      expect(shell.options, ScreenOptions.forNewHost);
    });

    test('no account for the cluster on this device: said so, and nothing is asked of anyone', () async {
      await start();
      final id = sessions().startConsole(await guestHost())!;
      await until(() => stateOf(id)?.status == SessionStatus.error, 'the console to be refused');
      expect(opened, isEmpty);
      expect(engine.sessions, isEmpty);
      expect(stateOf(id)!.errorMessage, contains(en.proxmoxConsoleNoAccount));
    });

    test('a refusal of the API is said in its words: the token, the permission', () async {
      await start(accounts: [lab]);
      refuseWith = const ProxmoxConsoleError(ProxmoxConsoleFailure.permission, 'vncproxy: 403');
      final id = sessions().startConsole(await guestHost())!;
      await until(() => stateOf(id)?.status == SessionStatus.error, 'the console to be refused');
      expect(stateOf(id)!.errorMessage, contains(en.proxmoxConsolePermission));
      expect(engine.sessions, isEmpty);
    });

    test('a host that names no guest offers no console', () async {
      await start(accounts: [lab]);
      final host = await guestHost(link: 'pve.example.test:8006/node/pve');
      expect(sessions().startConsole(host), isNull);
    });
  });
}

class _Store extends CloudAccountStore {
  _Store(this.accounts) : super(const FlutterSecureStorage());
  final List<CloudAccount> accounts;

  @override
  Future<List<CloudAccount>> load() async => accounts;
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

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
