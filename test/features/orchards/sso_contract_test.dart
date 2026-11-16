import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/services/sign_in_code.dart';

import '../../helpers/contract_run.dart';

/// Company sign-in against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js, routes/sso.js and lib/orchard_sso.js) on a real
/// Postgres (3.0): an owner sets a provider up once a
/// domain is proven, tests a sign-in through it, turns it on, and "Sign in
/// with SSO" finds it; the rule "Sign in with SSO" holds back a member who
/// signed in some other way; the provider cannot be removed while the rules
/// require it. The contract server's Identity Platform is stubbed (it lists
/// what it was asked at /test/sso/calls). Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Account {
  _Account(this.uid, this.domain, this.server, this.service, this.sso, this.domains, this.signIn);

  final String uid;
  final String domain;
  final OrchardsApi server;
  final OrchardService service;
  final OrchardSsoApi sso;
  final OrchardDomainsApi domains;

  /// How the account signs in from now on: 'provider' (google.com unless
  /// set), 'at' (when; now unless set).
  final Map<String, Object> signIn;

  String get email => '$uid@$domain';
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];
  final certificate = File('test/fixtures/sso_idp_cert.pem').readAsStringSync();

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      final sso = await client.get(Uri.parse('$base/sso/lookup?domain=nobody.example')).timeout(const Duration(seconds: 2));
      // The sign-in gate answers a call without its key.
      final gate = await client.post(Uri.parse('$base/sso-gate')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401 && sso.statusCode == 404 && gate.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  var made = 0;

  Future<_Account> account(String name, String domain) async {
    final uid = 'sso-$name-$contractRun-${made++}';
    final signIn = <String, Object>{};
    Future<String> token() async =>
        'fb:$uid:${signIn['at'] ?? now()}:${now()}::$domain:${signIn['provider'] ?? 'google.com'}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: token),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final storage = _MemoryStorage();
    opened.add(storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: token);
    final service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(
      uid,
      domain,
      server,
      service,
      OrchardSsoApi(client: client, baseUrl: base, bearer: token),
      OrchardDomainsApi(client: client, baseUrl: base, bearer: token),
      signIn,
    );
  }

  /// A Firebase sign-in through [provider] as [who], at their domain unless given.
  String idToken(_Account who, String provider, {String? domain}) =>
      'fb:${who.uid}:${now()}:${now()}::${domain ?? who.domain}:$provider';

  /// That sign-in, for an owner's test on a phone (the ID token itself).
  SsoTestSignIn signedIn(_Account who, String provider, {String? domain}) =>
      SsoTestSignIn.idToken(idToken(who, provider, domain: domain));

  Future<void> prove(_Account owner, String orchardId, String domain) async {
    final claim = await owner.domains.claim(orchardId, domain);
    final r = await client.put(Uri.parse('$root/test/dns/$domain'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'records': [claim.txt],
        }));
    expect(r.statusCode, 200);
    expect((await owner.domains.verify(orchardId, domain)).verified, isTrue);
  }

  Future<List<Object?>> platformCalls() async =>
      (jsonDecode((await client.get(Uri.parse('$root/test/sso/calls'))).body) as Map)['calls'] as List;

  Matcher refused(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  // The sign-in gate: no Identity Platform runs the
  // blocking function here, so the test asks the gate itself, as the
  // function would before Firebase lets a sign-in through an Orchard's
  // provider (the server's test/helpers/app_contract_server.js holds the key).
  const gateKey = 'app-contract-gate-key-0123456789abcdefghijk';
  Future<void> seenByGate(String provider, String email) async {
    final r = await client.post(Uri.parse('$base/sso-gate'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $gateKey'},
        body: jsonEncode({
          'provider_id': provider,
          'addresses': [email],
        }));
    expect(r.statusCode, 200, reason: r.body);
    expect(jsonDecode(r.body), {'allow': true});
  }

  test('set up once a domain is proven, tested, turned on and found by its domain; switched to OIDC', () async {
    if (!serverUp) return markTestSkipped('app contract server (with company sign-in and its gate) not running at $base');
    final domain = 'sso${now()}${made++}.example';
    final owner = await account('owner', domain);
    final alice = await account('alice', domain);
    final orchard = await owner.service.createOrchard('SSO', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await owner.service.invite(orchard, email: alice.email, role: role);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);

    // Nothing yet: what to tell the company's provider, and no domain.
    var sso = await owner.sso.get(orchard);
    expect(sso.isSetUp, isFalse);
    expect(sso.service.samlAcsUrl, 'https://zestssh-contract.firebaseapp.com/__/auth/handler');
    expect(sso.service.samlEntityId, matches(RegExp(r'^urn:zestssh:orchard:[0-9a-f]{32}$')));
    expect(sso.service.oidcRedirectUri, sso.service.samlAcsUrl);
    expect(sso.domains, isEmpty);
    Future<OrchardSso> setSaml({String cert = '', String url = 'https://idp.example.com/sso'}) => owner.sso.setSaml(
          orchard,
          displayName: 'Example SSO',
          ssoUrl: url,
          idpEntityId: 'https://idp.example.com/entity',
          certificate: cert.isEmpty ? certificate : cert,
        );
    await expectLater(setSaml(), refused('domain-required'));

    await prove(owner, orchard, domain);
    await expectLater(
      setSaml(cert: 'not a certificate'),
      throwsA(isA<SsoFieldInvalid>().having((e) => e.field, 'field', 'certificate')),
    );
    await expectLater(
      setSaml(url: 'http://idp.example.com/sso'),
      throwsA(isA<SsoFieldInvalid>().having((e) => e.field, 'field', 'sso_url')),
    );
    sso = await setSaml();
    expect(sso.kind, SsoKind.saml);
    expect(sso.providerId, matches(RegExp(r'^saml\.zo-[0-9a-f]{32}$')));
    expect((sso.active, sso.isTested), (false, false));
    expect(sso.domains, [domain]);
    expect(sso.config['certificate_sha256'], matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')));
    expect(sso.certificateValidTo!.isAfter(DateTime.now()), isTrue);
    final saml = sso.providerId!;
    final calls = await platformCalls();
    expect(calls.last, [
      'create',
      containsPair('providerId', saml),
    ]);

    // Only owners; not on before a test; a test that proves nothing.
    await expectLater(alice.sso.get(orchard), refused('forbidden'));
    await expectLater(owner.sso.activate(orchard), refused('sso-not-tested'));
    await expectLater(owner.sso.test(orchard, signedIn(owner, 'google.com')), refused('sso-test-failed'));
    await expectLater(owner.sso.test(orchard, signedIn(owner, saml, domain: 'elsewhere.example')),
        refused('sso-domain-mismatch'));
    expect(await OrchardSsoApi.lookup(domain, client: client, baseUrl: base), isNull);

    // Not before the sign-in gate saw that sign-in: the proof that the
    // blocking function stands.
    await expectLater(owner.sso.test(orchard, signedIn(owner, saml)), refused('sso-gate-not-seen'));
    await seenByGate(saml, owner.email);
    sso = await owner.sso.test(orchard, signedIn(owner, saml));
    expect(sso.isTested, isTrue);
    expect(sso.testedEmail, owner.email);

    // From a computer: the code the website got for the sign-in, with this
    // app's secret; not with another secret, and once.
    final secret = SignInCode.make();
    Future<String> codeFor() async {
      final r = await client.post(Uri.parse('$base/auth/sso-test/code'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id_token': idToken(owner, saml), 'challenge': secret.challenge}));
      expect(r.statusCode, 200, reason: r.body);
      return (jsonDecode(r.body) as Map)['code'] as String;
    }

    await expectLater(owner.sso.test(orchard, SsoTestSignIn.code(await codeFor(), SignInCode.make().verifier)),
        refused('sso-test-failed'));
    final code = await codeFor();
    sso = await owner.sso.test(orchard, SsoTestSignIn.code(code, secret.verifier));
    expect((sso.isTested, sso.testedEmail), (true, owner.email));
    await expectLater(owner.sso.test(orchard, SsoTestSignIn.code(code, secret.verifier)), refused('sso-test-failed'));
    sso = await owner.sso.activate(orchard);
    expect(sso.active, isTrue);
    final found = await OrchardSsoApi.lookup(domain.toUpperCase(), client: client, baseUrl: base);
    expect((found!.providerId, found.displayName, found.kind), (saml, 'Example SSO', SsoKind.saml));

    // To OIDC: a provider of its own, off until tested; the secret stays
    // when it is left out.
    sso = await owner.sso.setOidc(orchard,
        displayName: 'Example OIDC', issuer: 'https://login.example.com/', clientId: 'client-1', clientSecret: 's3');
    expect(sso.kind, SsoKind.oidc);
    expect(sso.providerId, 'oidc.zo-${saml.substring('saml.zo-'.length)}');
    expect(sso.config, {'issuer': 'https://login.example.com/', 'client_id': 'client-1'});
    expect(sso.active, isFalse);
    expect(await OrchardSsoApi.lookup(domain, client: client, baseUrl: base), isNull);
    sso = await owner.sso.setOidc(orchard,
        displayName: 'Example OIDC', issuer: 'https://login.example.com/', clientId: 'client-2');
    final last = (await platformCalls()).last as List;
    expect(last[0], 'update');
    expect((last[2] as Map).containsKey('clientSecret'), isFalse);
  });

  test("the rule 'Sign in with SSO': a member signed in some other way is held back; it keeps the provider in place", () async {
    if (!serverUp) return markTestSkipped('app contract server (with company sign-in and its gate) not running at $base');
    final domain = 'rule${now()}${made++}.example';
    final owner = await account('owner', domain);
    final alice = await account('alice', domain);
    final orchard = await owner.service.createOrchard('SSO rule', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await owner.service.invite(orchard, email: alice.email, role: role);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);
    await prove(owner, orchard, domain);
    final provider = (await owner.sso.setSaml(orchard,
            displayName: 'Rule SSO',
            ssoUrl: 'https://idp.example.com/sso',
            idpEntityId: 'https://idp.example.com/entity',
            certificate: certificate))
        .providerId!;
    await seenByGate(provider, owner.email);
    await owner.sso.test(orchard, signedIn(owner, provider));
    await owner.sso.activate(orchard);

    // Not while the owner signed in some other way.
    await expectLater(
      owner.service.setRules(orchard, const RecordRules(requireSso: true)),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.code, 'code', 'rules-unmet-by-you')
          .having((e) => e.unmet, 'unmet', ['sso'])),
    );
    owner.signIn['provider'] = provider;
    await owner.service.setRules(orchard, const RecordRules(requireSso: true));

    // Alice, through Google: held back, and told why.
    expect(await alice.service.refresh(), isNot(contains(orchard)));
    await expectLater(
      alice.server.record(orchard, after: 0),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.rulesUnmet, 'rulesUnmet', isTrue)
          .having((e) => e.unmet, 'unmet', ['sso'])),
    );
    // Another company's sign-in is not this one's: one with no settings at
    // ZestSSH Cloud, which cannot be told from one that was removed, is
    // answered as one that is gone, so the app signs that
    // account out with words of its own.
    alice.signIn['provider'] = 'saml.zo-${'0' * 32}';
    await expectLater(alice.server.record(orchard, after: 0), refused('sso-removed'));
    alice.signIn['provider'] = provider;
    expect(await alice.service.refresh(), contains(orchard));
    expect((await alice.server.record(orchard, after: 0)).entries, isNotEmpty);

    // The provider stays while the rules require it.
    await expectLater(owner.sso.remove(orchard), refused('sso-required-by-rules'));
    await owner.service.setRules(orchard, RecordRules.none);
    await owner.sso.remove(orchard);
    expect(await OrchardSsoApi.lookup(domain, client: client, baseUrl: base), isNull);
    // A sign-in through a company sign-in that is gone no longer counts,
    // and says so as its own answer (so the app signs out cleanly).
    await expectLater(owner.sso.get(orchard), refused('sso-removed'));
    owner.signIn.remove('provider');
    expect((await owner.sso.get(orchard)).isSetUp, isFalse);
  });

  test('a work address finds its domain; anything else is not one', () {
    expect(workAddressDomain(' Ann@Corp.Example. '), 'corp.example');
    for (final bad in ['', 'ann', '@corp.example', 'ann@localhost', 'ann@-corp.example', 'ann@corp..example']) {
      expect(workAddressDomain(bad), isNull, reason: bad);
    }
    expect(isOrchardSsoProvider('saml.zo-${'a' * 32}'), isTrue);
    expect(isOrchardSsoProvider('oidc.zo-${'0' * 32}'), isTrue);
    for (final bad in ['google.com', 'saml.zo-${'a' * 31}', 'saml.zo-${'A' * 32}', 'saml.zo-${'a' * 33}', null]) {
      expect(isOrchardSsoProvider(bad), isFalse, reason: bad);
    }
  });
}
