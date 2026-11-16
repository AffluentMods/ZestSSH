import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_approvals.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';

/// Connecting with a password from the person's password manager (3.0):
/// fetched and never kept; in an Orchard, where others can change the
/// key or the host, the person says yes the first time a password goes to
/// an address on this device, having seen what their password manager says
/// the item is; a changed host or item asks again; a phone asks the person
/// to type it (or fill it); a failure says why and lets them type it once.

class _Runner implements PmProcessRunner {
  _Runner(this.answer);

  PmProcessResult Function(List<String> args) answer;
  final calls = <List<String>>[];

  @override
  Future<PmProcessResult> run(String executable, List<String> args,
      {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async {
    calls.add(args);
    return answer(args);
  }
}

class _Asker implements PasswordManagerAsker {
  bool allow = true;
  String? typed = 'typed-once';
  final approvals = <(String, String)>[];
  final typedFor = <(String, PmFailure?, String?)>[];

  @override
  Future<bool> approve(PasswordManagerKind kind, PasswordRefDescription item, String destination) async {
    approvals.add((item.title, destination));
    return allow;
  }

  @override
  Future<String?> typeOnce(PasswordManagerKind kind, String destination, {PmFailure? failure, String? details}) async {
    typedFor.add((destination, failure, details));
    return typed;
  }

  @override
  Future<String?> unlock(PasswordManagerKind kind, {required bool again}) async => 'master';
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase tree;
  late AppDatabase orchard;
  late _Runner runner;
  late PasswordManagers managers;
  late _Asker asker;

  setUp(() {
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    runner = _Runner((args) => const PmProcessResult(0, 's3cret', ''));
    managers = PasswordManagers(
      runner: runner,
      settings: () => const PasswordManagerSettings(),
      environment: const {'PATH': '/usr/bin'},
      exists: (_) => true,
      isWindows: false,
      isMacOS: false,
    );
    asker = _Asker();
  });

  tearDown(() async {
    await tree.close();
    await orchard.close();
  });

  Identity key({String ref = 'op://Private/Bank/password', String id = 'k1'}) => Identity(
        id: id,
        label: 'Deploy',
        username: 'deploy',
        authMethod: 'passwordManager',
        passwordRef: PasswordRef.onePassword(ref)?.encode(),
        usesAgent: false,
        colorIndex: 0,
        isDefault: false,
        allowUnattended: false,
        passwordAfterKey: false,
        createdAt: DateTime(2026),
      );

  Future<String?> connect(AppDatabase db, Identity identity, {String host = 'web1.example.com', int port = 22, bool phone = false}) =>
      managedPassword(db, identity,
          username: identity.username, host: host, port: port, managers: phone ? null : managers, asker: asker);

  test('a Tree: fetched at once, nothing asked, nothing kept', () async {
    expect(await connect(tree, key()), 's3cret');
    expect(asker.approvals, isEmpty);
    expect(runner.calls.single, ['read', '--no-newline', '--', 'op://Private/Bank/password']);
    expect(await LocalStateStoreProbe.keys(tree), isEmpty);
  });

  test('an Orchard: the yes names the item and where it goes, once for each address; a changed host or item asks again',
      () async {
    expect(await connect(orchard, key()), 's3cret');
    expect(asker.approvals, [('Bank', 'deploy@web1.example.com:22')]);
    expect(await connect(orchard, key()), 's3cret');
    expect(asker.approvals, hasLength(1), reason: 'allowed before on this device');

    // Someone points the host at their own server.
    expect(await connect(orchard, key(), host: 'evil.example.com'), 's3cret');
    expect(asker.approvals.last, ('Bank', 'deploy@evil.example.com:22'));
    // Or the key at another item.
    expect(await connect(orchard, key(ref: 'op://Private/Email/password')), 's3cret');
    expect(asker.approvals.last, ('Email', 'deploy@web1.example.com:22'));
    // Another port is another address.
    await connect(orchard, key(), port: 2222);
    expect(asker.approvals, hasLength(4));
  });

  test('an Orchard: declined, nothing is fetched and the connection stops', () async {
    asker.allow = false;
    await expectLater(connect(orchard, key()), throwsA(isA<PasswordRefNotAllowed>()));
    expect(runner.calls, isEmpty, reason: 'the password manager was never asked for it');
    // And not remembered as allowed.
    asker.allow = true;
    await connect(orchard, key());
    expect(asker.approvals, hasLength(2));
  });

  // A run with nobody there (automation) asks nobody: it gets the password
  // where no question is needed, and stops at the first one otherwise (it
  // once asked on screen and waited two minutes).
  group('with nobody there', () {
    final stop = StateError('nobody to ask');
    Future<String?> unattended(AppDatabase db, Identity identity, {bool phone = false}) => managedPassword(db, identity,
        username: identity.username,
        host: 'web1.example.com',
        port: 22,
        managers: phone ? null : managers,
        asker: NobodyToAsk(() => stop));

    test('an unlocked manager and a key of one\'s own: fetched, with no question', () async {
      expect(await unattended(tree, key()), 's3cret');
    });

    test('a team key allowed for this address before: fetched; a new address stops, and nothing is fetched', () async {
      await expectLater(unattended(orchard, key()), throwsA(same(stop)));
      expect(runner.calls.where((c) => c.first == 'read'), isEmpty, reason: 'the password was never asked for');
      // Its person says yes once, in the app.
      expect(await connect(orchard, key()), 's3cret');
      expect(await unattended(orchard, key()), 's3cret');
    });

    test('a phone, which can only ask for it to be typed: stops', () async {
      await expectLater(unattended(tree, key(), phone: true), throwsA(same(stop)));
    });

    test('a manager that does not give it: stops, where a person would be asked to type it', () async {
      runner.answer = (_) => const PmProcessResult(1, '', '[ERROR] account is not signed in');
      await expectLater(unattended(tree, key()), throwsA(same(stop)));
    });

    test('the session passes it whenever the run is unattended', () {
      final source = File('lib/providers/terminal_providers.dart').readAsStringSync();
      expect('PromptedAsker('.allMatches(source), hasLength(1));
      expect(source, contains('asker: unattended'));
      expect(source, contains('? NobodyToAsk(() => UnattendedSignInStopped(gl10n.unattendedNobodyToAsk))'));
    });
  });

  test('a phone: typed, or filled by the phone\'s password manager, never fetched', () async {
    expect(await connect(orchard, key(), phone: true), 'typed-once');
    expect(asker.typedFor.single, ('deploy@web1.example.com:22', null, null));
    expect(runner.calls, isEmpty);
  });

  test('a failure says why and what the tool said, and the person may type it once; stopped in the manager, it stops',
      () async {
    runner.answer = (_) => const PmProcessResult(1, '', '[ERROR] account is not signed in');
    expect(await connect(tree, key()), 'typed-once');
    expect(asker.typedFor.single, ('deploy@web1.example.com:22', PmFailure.notSignedIn, '[ERROR] account is not signed in'));

    asker.typed = null;
    expect(await connect(tree, key()), isNull, reason: 'they cancelled the typing');

    runner.answer = (_) => const PmProcessResult(1, '', '[ERROR] authorization prompt dismissed');
    asker.typed = 'x';
    expect(await connect(tree, key()), isNull, reason: 'they said no in 1Password');
    expect(asker.typedFor, hasLength(2));
  });

  test('a key with no reference, or a bad one, never reaches a password manager', () async {
    final bad = key().copyWith(passwordRef: const Value('{"v":1,"m":"op","t":"--version"}'));
    await expectLater(connect(tree, bad), throwsA(isA<PasswordRefMissing>()));
    await expectLater(connect(tree, key().copyWith(passwordRef: const Value(null))), throwsA(isA<PasswordRefMissing>()));
    expect(runner.calls, isEmpty);
  });

  test('what is remembered names neither the item nor the host', () async {
    await connect(orchard, key());
    final stored = await LocalStateStoreProbe.values(orchard);
    expect(stored.join(), isNot(contains('web1')));
    expect(stored.join(), isNot(contains('Bank')));
    expect(stored.join(), contains(passwordRefUseOf(
        identityId: 'k1',
        ref: PasswordRef.onePassword('op://Private/Bank/password')!,
        username: 'deploy',
        host: 'web1.example.com',
        port: 22)));
  });
}

/// Reads a database's device-local state directly.
abstract final class LocalStateStoreProbe {
  static Future<List<String>> keys(AppDatabase db) async =>
      [for (final r in await db.select(db.localState).get()) r.key];

  static Future<List<String>> values(AppDatabase db) async =>
      [for (final r in await db.select(db.localState).get()) r.value];
}
