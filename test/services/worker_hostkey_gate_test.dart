import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/worker/ssh_callback_router.dart';

/// MERGE GATE for Design B (per-connection worker isolate).
///
/// The one thing that can make Design B insecure is a worker isolate that
/// self-approves a host key instead of routing the decision back to the main
/// isolate's real [KnownHostsService.verify]. This test proves the seam:
/// [SshCallbackRouter] makes NO trust decision of its own - it forwards the
/// presented key to the injected verifier (the same closure shape
/// `_buildHostKeyVerifier()` produces) and returns exactly what that verifier
/// decides. A changed key, a changed key TYPE, and a route-scoped
/// (`viaScope`) lookup must all reach the real DB-backed verifier and be
/// honored across the boundary. It also proves the credential-protection rule
/// (2FA/OTP prompts never get the account password) runs on this main-isolate
/// seam.
///
/// It runs with `flutter test`, no network, no isolate: the router is pure
/// main-isolate logic and the verifier it forwards to is the real service over
/// an in-memory DB.
void main() {
  late AppDatabase db;
  late KnownHostsService svc;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    svc = KnownHostsService(db.knownHostsDao);
  });
  tearDown(() => db.close());

  // Distinct key blobs -> distinct fingerprints.
  Uint8List blob(int seed) =>
      Uint8List.fromList(List<int>.generate(48, (i) => (seed + i) & 0xff));

  /// A faithful stand-in for the app's `_buildHostKeyVerifier()` closure: runs
  /// the REAL [KnownHostsService.verify], auto-trusts on `trusted`, and on
  /// `newHost` / `changed` defers to a prompt whose answer the test controls -
  /// the exact verify -> prompt -> trust security structure, minus the Riverpod
  /// UI plumbing. This is the shape the blueprint's gate test prescribes.
  HostKeyVerifyCallback verifier(
    Future<bool> Function() prompt, {
    String? viaScope,
    void Function()? onPromptShown,
    void Function()? onCalled,
  }) {
    return (host, port, hostKey) async {
      onCalled?.call();
      final outcome =
          await svc.verify(host, port, hostKey, viaScope: viaScope);
      switch (outcome.result) {
        case HostKeyVerifyResult.trusted:
          return true;
        case HostKeyVerifyResult.newHost:
        case HostKeyVerifyResult.changed:
          onPromptShown?.call();
          final accepted = await prompt();
          if (accepted) {
            await svc.trustHost(host, port, hostKey, viaScope: viaScope);
          }
          return accepted;
      }
    };
  }

  group('host-key gate: the router forwards, never self-approves', () {
    test('Case A - a CHANGED key is rejected when the user declines', () async {
      // TOFU an ed25519 key for h:22.
      await svc.trustHost('h', 22, SSHHostKey(type: 'ssh-ed25519', bytes: blob(1)));

      var prompts = 0;
      final router = SshCallbackRouter(
        host: 'h',
        port: 22,
        onHostKeyVerify:
            verifier(() async => false, onPromptShown: () => prompts++),
      );

      // A DIFFERENT key blob for the same host/type: verify() must see it as
      // `changed`, the prompt is shown, and (declined) the router returns false.
      final accepted = await router.verifyHostKey('ssh-ed25519', blob(200));
      expect(accepted, isFalse, reason: 'declined changed key must be rejected');
      expect(prompts, 1, reason: 'the changed-key prompt is shown exactly once');
    });

    test('Case A2 - the SAME (trusted) key is accepted with no prompt',
        () async {
      final key = blob(1);
      await svc.trustHost('h', 22, SSHHostKey(type: 'ssh-ed25519', bytes: key));

      var prompts = 0;
      final router = SshCallbackRouter(
        host: 'h',
        port: 22,
        onHostKeyVerify:
            verifier(() async => false, onPromptShown: () => prompts++),
      );

      final accepted = await router.verifyHostKey('ssh-ed25519', key);
      expect(accepted, isTrue);
      expect(prompts, 0, reason: 'a matching key is trusted silently');
    });

    test('Case B - a changed key TYPE is treated as changed, not a new host',
        () async {
      // Trusted under ssh-rsa; a MITM presents ssh-ed25519 for the same host.
      await svc.trustHost('h', 22, SSHHostKey(type: 'ssh-rsa', bytes: blob(50)));

      var prompts = 0;
      final router = SshCallbackRouter(
        host: 'h',
        port: 22,
        onHostKeyVerify:
            verifier(() async => false, onPromptShown: () => prompts++),
      );

      final accepted = await router.verifyHostKey('ssh-ed25519', blob(99));
      expect(accepted, isFalse,
          reason: 'a different key type for a known host is a change, '
              'must not silently re-TOFU');
      expect(prompts, 1);
    });

    test('Case C - viaScope route scoping is applied MAIN-side, not lost at '
        'the boundary', () async {
      // Two records for the SAME host:port with DIFFERENT keys: one scoped to a
      // bastion route, one direct (NULL scope).
      final scopedKey = blob(10);
      final directKey = blob(210);
      await svc.trustHost('h', 22, SSHHostKey(type: 'ssh-ed25519', bytes: scopedKey),
          viaScope: 'bastionA');
      await svc.trustHost('h', 22, SSHHostKey(type: 'ssh-ed25519', bytes: directKey));

      // A verifier bound to the bastion route.
      SshCallbackRouter routerFor(Future<bool> Function() prompt) =>
          SshCallbackRouter(
            host: 'h',
            port: 22,
            onHostKeyVerify: verifier(prompt, viaScope: 'bastionA'),
          );

      // Presenting the SCOPED key over the bastion route -> trusted.
      expect(await routerFor(() async => false)
          .verifyHostKey('ssh-ed25519', scopedKey), isTrue,
          reason: 'the scoped record is the one consulted for this route');

      // Presenting the DIRECT-route key over the bastion route -> changed
      // (declined -> false). Proves the scoped record, not the NULL-scope one,
      // was used: if scope were dropped, the direct key would look trusted.
      expect(await routerFor(() async => false)
          .verifyHostKey('ssh-ed25519', directKey), isFalse,
          reason: 'wrong-route key must not be trusted via the bastion scope');
    });

    test('Case D - the router has no self-approve path: it returns exactly what '
        'the verifier decides, and always calls it', () async {
      // Verifier that unconditionally rejects and records that it ran.
      var called = false;
      final router = SshCallbackRouter(
        host: 'h',
        port: 22,
        onHostKeyVerify:
            verifier(() async => false, onCalled: () => called = true),
      );
      // A brand-new host (nothing seeded) with the prompt declining.
      final accepted = await router.verifyHostKey('ssh-ed25519', blob(7));
      expect(called, isTrue,
          reason: 'the router must consult the verifier, never short-circuit');
      expect(accepted, isFalse);
    });
  });

  group('credential protection runs on the router (main isolate)', () {
    SshCallbackRouter withPassword(String? pw) => SshCallbackRouter(
          host: 'h',
          port: 22,
          onHostKeyVerify: (_, _, _) async => true,
          password: pw,
        );

    test('the account password answers ONLY a real password prompt, once',
        () {
      final answers = withPassword('hunter2').userInfoResponse('PAM', const [
        (promptText: 'Password:', echo: false),
        (promptText: 'Verification code:', echo: false), // 2FA/OTP
        // A second password prompt means the first was not taken; repeating
        // it would only count towards a lockout (shared answerer rule).
        (promptText: "bob's password:", echo: false),
        (promptText: 'Username:', echo: true), // echoed field
      ]);
      expect(answers, ['hunter2', '', '', '']);
    });

    test('no password configured -> hasPassword false, all prompts empty', () {
      final r = withPassword(null);
      expect(r.hasPassword, isFalse);
      expect(r.passwordRequest(), isNull);
      expect(
        r.userInfoResponse('PAM', const [(promptText: 'Password:', echo: false)]),
        [''],
      );
    });

    test('password configured -> passwordRequest returns it', () {
      final r = withPassword('hunter2');
      expect(r.hasPassword, isTrue);
      expect(r.passwordRequest(), 'hunter2');
    });
  });
}
