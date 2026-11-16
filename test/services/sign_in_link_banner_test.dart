import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The messages a played server sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/worker/worker_protocol.dart' show ConnectParams;
import 'package:zestssh/services/worker/worker_ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_jump_host.dart';

/// A login banner with a link the sign-in waits on (a reported
/// case): Tailscale SSH in "check" mode answers the first sign-in
/// request with a banner ("To authenticate, visit: https://login.tailscale.com/a/...")
/// and says yes only once the person has approved it on that page. The
/// banner waited for the shell, which never came: the sign-in ended at its
/// 15 seconds ([SignInTimedOut]) before anyone could have seen the link. On
/// a phone nothing showed it at all.
///
/// The host is played by the test; the sign-in's usual time is one second
/// here ([AuthDeadline.debugPatience]), and the host waits longer than that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const tailscale = '# Tailscale SSH requires an additional check.\n'
      '# To authenticate, visit: https://login.tailscale.com/a/l1b2c3d4e5f6\n';

  setUp(() {
    L10nGlobal.update(en);
    AuthDeadline.debugPatience = const Duration(seconds: 1);
  });
  tearDown(() => AuthDeadline.debugPatience = null);

  group('the banner, cleaned', () {
    test('Tailscale\'s: its words, and its link to open', () {
      final notice = SignInNotice.of(tailscale);
      expect(notice.text, tailscale.trim());
      expect(notice.link, Uri.parse('https://login.tailscale.com/a/l1b2c3d4e5f6'));
      expect(notice.link!.host, 'login.tailscale.com');
    });

    test('no escape sequences, control characters or invisible ones: a link hidden in an escape sequence is '
        'neither shown nor offered', () {
      final notice = SignInNotice.of('\x1b[1;31mWarning\x1b[0m \x1b]0;a title\x07'
          '\x1b]8;;https://hidden.example/\x1b\\click\x1b]8;;\x1b\\ here\x07\x00\x1bc'
          '\r\nline \u202Etwo\u202C\x7f\x9b2J');
      expect(notice.text, 'Warning click here\nline two');
      expect(notice.link, isNull);
    });

    test('only an https link, with a host and no user name before it; trailing punctuation is not part of it', () {
      expect(SignInNotice.of('visit http://login.example.com/a/1').link, isNull);
      expect(SignInNotice.of('visit javascript:alert(1)').link, isNull);
      expect(SignInNotice.of('visit https://login.example.com@other.example/a').link, isNull);
      expect(SignInNotice.of('visit https:///nohost').link, isNull);
      expect(SignInNotice.of('(see https://login.example.com/a/b).').link, Uri.parse('https://login.example.com/a/b'));
      expect(SignInNotice.of('HTTPS://Login.Example.com/x, then wait').link!.host, 'login.example.com');
      // The first that is one.
      expect(SignInNotice.of('http://a.example https://b.example/c https://d.example').link!.host, 'b.example');
    });

    test('a link to a bare address is not offered', () {
      expect(SignInNotice.of('visit https://127.0.0.1/x').link, isNull);
      expect(SignInNotice.of('visit https://[::1]:8443/x').link, isNull);
      expect(SignInNotice.of('visit https://203.0.113.9/a then https://login.example.com/b').link!.host, 'login.example.com');
    });

    test('a long banner is cut, and a link past what is shown is still offered', () {
      final notice = SignInNotice.of('${'x' * 5000}\nhttps://login.example.com/a/1');
      expect(notice.text.length, kSignInNoticeMax + 1);
      expect(notice.text, endsWith('…'));
      expect(notice.link, Uri.parse('https://login.example.com/a/1'));
    });
  });

  /// A connection to a played host that signs in with nothing ("none", as
  /// Tailscale SSH does), whose banners go to [show].
  ({PlayedServer server, SshService ssh}) connection({SignInNoticeShower? show}) {
    final server = PlayedServer();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      onSignInNotice: show,
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    return (server: server, ssh: ssh);
  }

  /// The host up to the client's first sign-in request, which it answers
  /// with [banner].
  Future<void> greetWithBanner(PlayedServer server, String banner) async {
    await server.greet();
    final first = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(first.methodName, 'none');
    server.send([SSH_Message_Userauth_Banner(message: banner, language: '').encode()]);
  }

  test('a banner with a link, and a host that says yes only after longer than a sign-in is given: the person '
      'is shown it at once, the sign-in waits, the session opens, and the notice is withdrawn', () async {
    final shown = <SignInNotice>[];
    final answered = Completer<bool>();
    final (:server, :ssh) = connection(show: (notice) {
      shown.add(notice);
      notice.withdrawn.then((_) {
        if (!answered.isCompleted) answered.complete(false);
      });
      return answered.future;
    });
    final out = <int>[];
    ssh.stdout.listen(out.addAll);
    Object? failure;
    var done = false;
    final connecting = ssh.connect().then<void>((_) => done = true, onError: (Object e) {
      failure = e;
      done = true;
    });
    await greetWithBanner(server, tailscale);
    await server.settle();
    expect(shown, hasLength(1), reason: 'the banner was not shown while the sign-in waited on it');
    expect(shown.single.link!.host, 'login.tailscale.com');

    // Longer than the sign-in's usual time: it still waits.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(done, isFalse, reason: 'the sign-in ended while its person had the link: $failure');

    server.send([SSH_Message_Userauth_Success().encode()]);
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
    await connecting;
    expect(failure, isNull);
    expect(ssh.isConnected, isTrue);
    // Withdrawn once signed in: not a cancel.
    expect(await answered.future, isFalse);
    // And the banner is in the terminal ahead of the prompt, as before.
    await server.settle();
    expect(utf8.decode(out, allowMalformed: true), contains('https://login.tailscale.com/a/l1b2c3d4e5f6'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Cancel at the link ends the sign-in at once, as a cancel and not a failure', () async {
    final (:server, :ssh) = connection(show: (_) => Future<bool>.delayed(const Duration(milliseconds: 300), () => true));
    final waited = Stopwatch()..start();
    final connecting = ssh.connect();
    await greetWithBanner(server, tailscale);
    await expectLater(connecting, throwsA(isA<SshPromptCancelled>()));
    expect(waited.elapsed, lessThan(const Duration(seconds: 5)));
    expect(ssh.isConnected, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a server that sends banner after banner is shown one notice, and the clock is stretched once', () {
    final shown = <SignInNotice>[];
    final deadline = AuthDeadline();
    final banners = SignInLinkBanners((n) async {
      shown.add(n);
      return false;
    }, deadline: deadline, withdrawn: Completer<void>().future);
    for (var i = 0; i < 500; i++) {
      banners.banner('visit https://login.example.com/a/$i');
    }
    expect(shown, hasLength(1));
    expect(shown.single.link!.path, '/a/0', reason: 'the first link is kept');
  });

  test('a banner with no link is not put to the person, and the sign-in gets no more time', () async {
    var shown = 0;
    final (:server, :ssh) = connection(show: (_) async {
      shown++;
      return false;
    });
    final connecting = ssh.connect();
    await greetWithBanner(server, 'Authorised users only. Activity is logged.');
    await expectLater(connecting, throwsA(isA<SignInTimedOut>()));
    expect(shown, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('with nobody to show it to (a run nobody watches), a banner with a link gets no more time either', () async {
    final (:server, :ssh) = connection();
    final waited = Stopwatch()..start();
    final connecting = ssh.connect();
    await greetWithBanner(server, tailscale);
    await expectLater(connecting, throwsA(isA<SignInTimedOut>()));
    expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  /// The connection worker (Design B, behind WORKER_CONN_ISOLATION, 3.4.1):
  /// its sign-in had a fixed 15 seconds and no banner hook, so a Tailscale
  /// SSH host in check mode showed no link and ended at 15 seconds. Run on
  /// this isolate ([WorkerSshService.debugInProcess]) so the played host's
  /// connection reaches it; the worker is the same code, over the same ports.
  group('on the connection worker', () {
    setUp(() => WorkerSshService.debugInProcess = true);
    tearDown(() {
      WorkerSshService.debugInProcess = false;
      SshService.debugOpenSocket = null;
    });

    /// A worker session to a played host that signs in with nothing, whose
    /// banners go to [show].
    ({PlayedServer server, WorkerSshService ssh}) onWorker({SignInNoticeShower? show}) {
      final server = PlayedServer();
      SshService.debugOpenSocket = (host, port, timeout) async => server.socket;
      final ssh = WorkerSshService(
        params: const ConnectParams(host: 'web-01.example.com', port: 22, username: 'deploy'),
        keyPems: const [],
        passphrase: null,
        password: null,
        forwardAgent: false,
        onHostKeyVerify: (_, _, _) async => true,
        onSignInNotice: show,
        fallbackFactory: () => throw StateError('the worker started: no fallback'),
      );
      addTearDown(ssh.disconnect);
      return (server: server, ssh: ssh);
    }

    test('a banner with a link: cleaned where it arrives, shown to the person at once, the sign-in waits past its '
        'usual time, the session opens, and the notice is withdrawn', () async {
      final shown = <SignInNotice>[];
      final answered = Completer<bool>();
      final (:server, :ssh) = onWorker(show: (notice) {
        shown.add(notice);
        notice.withdrawn.then((_) {
          if (!answered.isCompleted) answered.complete(false);
        });
        return answered.future;
      });
      Object? failure;
      var done = false;
      final connecting = ssh.connect().then<void>((_) => done = true, onError: (Object e) {
        failure = e;
        done = true;
      });
      await greetWithBanner(server, '\x1b[1m$tailscale\x1b[0m');
      await server.settle();
      expect(shown, hasLength(1), reason: 'the banner was not shown while the sign-in waited on it');
      expect(shown.single.text, tailscale.trim(), reason: 'its escape sequences taken out');
      expect(shown.single.link, Uri.parse('https://login.tailscale.com/a/l1b2c3d4e5f6'));

      // Longer than the sign-in's usual time: it still waits.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(done, isFalse, reason: 'the sign-in ended while its person had the link: $failure');

      server.send([SSH_Message_Userauth_Success().encode()]);
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'pty-req');
      server.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
      await connecting;
      expect(failure, isNull);
      expect(ssh.isConnected, isTrue);
      expect(await answered.future, isFalse, reason: 'withdrawn once signed in: not a cancel');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('shown through the app\'s notice queue, as every watched sign-in is; Cancel there ends the sign-in at once, '
        'as a cancel and not a failure', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final shower = Provider<SignInNoticeShower>((ref) => signInNoticeShower(ref,
          host: 'web-01.example.com', port: 22, username: 'deploy', purpose: SignInNoticeFor.session));
      final (:server, :ssh) = onWorker(show: container.read(shower));
      final waited = Stopwatch()..start();
      final connecting = ssh.connect();
      await greetWithBanner(server, tailscale);
      final clock = Stopwatch()..start();
      while (container.read(signInNoticeQueueProvider).isEmpty) {
        if (clock.elapsed > const Duration(seconds: 10)) fail('the notice was not queued');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final request = container.read(signInNoticeQueueProvider).single;
      expect(request.host, 'web-01.example.com');
      expect(request.notice.link!.host, 'login.tailscale.com');
      request.cancel();
      await expectLater(connecting, throwsA(isA<SshPromptCancelled>()));
      expect(waited.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ssh.isConnected, isFalse);
      expect(container.read(signInNoticeQueueProvider), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('with nobody to show it to (a run nobody watches), a banner with a link gets no more time', () async {
      final (:server, :ssh) = onWorker();
      final waited = Stopwatch()..start();
      final connecting = ssh.connect();
      await greetWithBanner(server, tailscale);
      await expectLater(
          connecting, throwsA(isA<WorkerConnectionException>().having((e) => '$e', 'message', contains('timed out'))));
      expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a banner with no link is not put to the person, and the sign-in gets no more time', () async {
      var shown = 0;
      final (:server, :ssh) = onWorker(show: (_) async {
        shown++;
        return false;
      });
      final waited = Stopwatch()..start();
      final connecting = ssh.connect();
      await greetWithBanner(server, 'Authorised users only. Activity is logged.');
      await expectLater(connecting, throwsA(isA<WorkerConnectionException>()));
      expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
      expect(shown, 0);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  /// The other sign-ins a person watches, as the app makes them (3.4): each
  /// jump host on the way, a run its person started (and not one nobody
  /// watches), a console server, a host's connection test. Each was given
  /// its usual time whatever its banner said, and none showed the link: a
  /// Tailscale SSH host in check mode could not be a jump host, be run on,
  /// or be tested.
  group('every sign-in a person watches', () {
    final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
    late AppDatabase tree;
    late ProviderContainer container;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
        connectionResolverProvider.overrideWithValue(_AsSaved()),
      ]);
      container.read(databaseSessionProvider.notifier).seed(tree);
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: 'id-deploy',
            label: 'deploy-key',
            username: 'deploy',
            authMethod: 'publicKey',
            allowUnattended: const Value(true),
            createdAt: DateTime(2026, 11, 6),
          ));
    });

    tearDown(() async {
      container.dispose();
      await tree.close();
    });

    List<SignInNoticeRequest> notices() => container.read(signInNoticeQueueProvider);

    Future<void> until(bool Function() check, String what) async {
      final clock = Stopwatch()..start();
      while (!check()) {
        if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    /// The jump host bastion, played by the test wherever the app dials it,
    /// and web-01 saved behind it; both their keys trusted on this device.
    /// Each connection to bastion is a new one in [dialled].
    Future<({List<PlayedJumpHost> dialled, PlayedHostKey webKey})> savedChain() async {
      final bastionKey = PlayedHostKey.ed25519();
      final webKey = PlayedHostKey.ed25519();
      final known = KnownHostsService(tree.knownHostsDao);
      await known.trustHost('bastion.example.com', 22, SSHHostKey(type: bastionKey.algorithm, bytes: bastionKey.blob));
      await known.trustHost('192.168.20.21', 22, SSHHostKey(type: webKey.algorithm, bytes: webKey.blob));
      final dialled = <PlayedJumpHost>[];
      SshService.debugOpenSocket = (host, port, timeout) async {
        expect(host, 'bastion.example.com', reason: 'only the jump host is dialled from here');
        final bastion = PlayedJumpHost(hostKey: bastionKey);
        addTearDown(bastion.stop);
        dialled.add(bastion);
        return bastion.server.socket;
      };
      addTearDown(() => SshService.debugOpenSocket = null);
      final at = DateTime(2026, 11, 6);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-bastion',
            label: 'bastion',
            host: 'bastion.example.com',
            port: const Value(22),
            identityId: const Value('id-deploy'),
            createdAt: at,
            updatedAt: at,
          ));
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-web',
            label: 'web-01',
            host: '192.168.20.21',
            port: const Value(22),
            identityId: const Value('id-deploy'),
            connectViaId: const Value('h-bastion'),
            createdAt: at,
            updatedAt: at,
          ));
      return (dialled: dialled, webKey: webKey);
    }

    /// bastion, dialled once more: it answers the first sign-in request
    /// with Tailscale's banner.
    Future<PlayedJumpHost> bastionWithBanner(({List<PlayedJumpHost> dialled, PlayedHostKey webKey}) chain) async {
      final before = chain.dialled.length;
      await until(() => chain.dialled.length > before, 'the jump host to be dialled');
      final bastion = chain.dialled.last;
      await greetWithBanner(bastion.server, tailscale);
      return bastion;
    }

    /// bastion says yes, and carries the way on to web-01, which lets the
    /// client in.
    Future<PlayedServer> approvedAndOn(PlayedJumpHost bastion, PlayedHostKey webKey) async {
      bastion.server.send([SSH_Message_Userauth_Success().encode()]);
      final web = PlayedServer(line: await bastion.carryToAPlayedServer(), hostKey: webKey);
      await web.letIn();
      return web;
    }

    /// The one notice shown, once it is.
    Future<SignInNoticeRequest> shownNotice() async {
      await until(() => notices().isNotEmpty, 'the notice');
      expect(notices(), hasLength(1));
      return notices().single;
    }

    test('a jump host whose banner has a link: the person is shown it, naming the jump host and where it leads, the '
        'sign-in to it waits, the session opens, and the notice is withdrawn', () async {
      final chain = await savedChain();
      final id = container.read(activeSessionsProvider.notifier).startSession((await tree.connectionsDao.getById('h-web'))!)!;
      SessionState? state() => container.read(activeSessionsProvider)[id];
      final bastion = await bastionWithBanner(chain);
      final notice = await shownNotice();
      expect(notice.host, 'bastion.example.com');
      expect(notice.username, 'deploy');
      expect(notice.jumpHost, 'bastion');
      expect(notice.onward, 'web-01');
      expect(notice.purpose, SignInNoticeFor.session);
      expect(notice.notice.link!.host, 'login.tailscale.com');

      // Longer than a sign-in is usually given: it still waits.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(state()?.status, SessionStatus.connecting, reason: '${state()?.errorMessage}');

      final web = await approvedAndOn(bastion, chain.webKey);
      final channel = await web.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'pty-req');
      web.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      web.send([channel.success]);
      await until(() => state()?.status == SessionStatus.connected || state()?.status == SessionStatus.error,
          'the session');
      expect(state()?.status, SessionStatus.connected, reason: '${state()?.errorMessage}');
      // Withdrawn once signed in to bastion: not a cancel.
      expect(await notice.cancelled, isFalse);
      expect(notices(), isEmpty);
      await container.read(activeSessionsProvider.notifier).endSession(id);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test("Cancel at a jump host's link ends the session's try at once, as a cancel: no error is shown", () async {
      final chain = await savedChain();
      final id = container.read(activeSessionsProvider.notifier).startSession((await tree.connectionsDao.getById('h-web'))!)!;
      await bastionWithBanner(chain);
      final notice = await shownNotice();
      final clock = Stopwatch()..start();
      notice.cancel();
      await until(() => container.read(activeSessionsProvider)[id] == null, 'the try to be dropped');
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(notices(), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a run its person started, through that jump host: shown as a run, it waits and runs; the same run with '
        'nobody there shows nothing and gets no more time', () async {
      final chain = await savedChain();
      final tasks = container.read(automationServiceProvider);

      final watched = tasks.executeCommand(connectionId: 'h-web', command: 'echo done');
      final bastion = await bastionWithBanner(chain);
      final notice = await shownNotice();
      expect(notice.jumpHost, 'bastion');
      expect(notice.onward, 'web-01');
      expect(notice.purpose, SignInNoticeFor.run);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final web = await approvedAndOn(bastion, chain.webKey);
      final channel = await web.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'exec');
      web.send([channel.success, channel.data('done\n'), channel.exitStatus(0), channel.eof, channel.close]);
      final ran = await watched;
      expect(ran.success, isTrue, reason: ran.error);
      expect(ran.output.trim(), 'done');
      expect(notices(), isEmpty);

      // Nobody there: no notice, and the jump host's sign-in times out as it did.
      final clock = Stopwatch()..start();
      final unattended = tasks.executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
      await bastionWithBanner(chain);
      final stopped = await unattended;
      expect(stopped.success, isFalse);
      expect(stopped.error, contains('bastion'));
      expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
      expect(notices(), isEmpty, reason: 'nobody is there to be shown it');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  test('a console server whose banner has a link: shown, the sign-in waits, and the console opens', () async {
    final server = PlayedServer();
    SshService.debugOpenSocket = (host, port, timeout) async => server.socket;
    addTearDown(() => SshService.debugOpenSocket = null);
    final shown = <SignInNotice>[];
    final console = SerialOverSshService(
      host: 'console-01.example.com',
      port: 3001,
      username: 'admin',
      serialConfig: SerialConfig.cisco(),
      onHostKeyVerify: (_, _, _) async => true,
      onSignInNotice: (notice) {
        shown.add(notice);
        return notice.withdrawn.then((_) => false);
      },
    );
    addTearDown(console.disconnect);
    Object? failure;
    var done = false;
    final connecting = console.connect().then<void>((_) => done = true, onError: (Object e) {
      failure = e;
      done = true;
    });
    await greetWithBanner(server, tailscale);
    await server.settle();
    expect(shown, hasLength(1), reason: 'the banner was not shown while the sign-in waited on it');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(done, isFalse, reason: 'the sign-in ended while its person had the link: $failure');
    server.send([SSH_Message_Userauth_Success().encode()]);
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
    await connecting;
    expect(failure, isNull);
    expect(console.isConnected, isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a connection test whose host has a link in its banner: shown as a test, its sign-in waits, and it '
      'says the host works', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final shows = PlayedHostKey.ed25519();
    final server = PlayedServer(hostKey: shows);
    await tester.runAsync(() => KnownHostsService(db.knownHostsDao)
        .trustHost('web-01.example.com', 22, SSHHostKey(type: shows.algorithm, bytes: shows.blob)));
    SshService.debugOpenSocket = (host, port, timeout) async => server.socket;
    addTearDown(() => SshService.debugOpenSocket = null);
    late BuildContext at;
    late WidgetRef widgetRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (context, ref, _) {
          at = context;
          widgetRef = ref;
          return const SizedBox();
        }),
      ),
    ));
    final shown = <SignInNoticeRequest>[];
    final result = await tester.runAsync(() async {
      final testing = HostTester(
        context: at,
        ref: widgetRef,
        addressChosenHere: (_) async => true,
        wouldGoUnwatched: (db, {hostId, keyId}) async => false,
        requireCratesOpen: (db, {hostId, keyId}) async {},
        showSignInNotice: (request) {
          shown.add(request);
          return request.cancelled;
        },
      ).fullConnection(const EffectiveTestConfig(host: 'web-01.example.com', port: 22, username: 'deploy'));
      await greetWithBanner(server, tailscale);
      await server.settle();
      expect(shown, hasLength(1), reason: 'the banner was not shown while the test waited on it');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      server.send([SSH_Message_Userauth_Success().encode()]);
      return testing;
    });
    expect(result!.success, isTrue, reason: result.message);
    expect(shown.single.purpose, SignInNoticeFor.test);
    expect(shown.single.host, 'web-01.example.com');
    expect(shown.single.username, 'deploy');
    expect(shown.single.isOpen, isFalse, reason: 'withdrawn once the test signed in');
  });
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

/// Each host as it is saved: no networks here.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
