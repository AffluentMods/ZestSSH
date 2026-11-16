import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What a login is told when it could get no team certificate (3.0).
/// It used to be told one of five things the record has
/// against it, or else "ZestSSH Cloud could not be reached, check your
/// connection", whatever had happened: the service refusing this device,
/// keys that are not there, a fault of the app's own. Each is said as what
/// it is now. Two of them an owner can get around by signing a certificate
/// directly: those say so, end in a code, and name the Crate, so that
/// whatever shows the failure can offer it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  TeamCertificateUnavailable unavailable(TeamCertificateProblem p) =>
      TeamCertificateUnavailable(p, userNames: const ['deploy']);

  /// What stopped a login, what it is told, and whether an owner can get around it.
  final cases = <(String, Object, String Function(AppLocalizations), bool)>[
    // The request waits for an owner.
    (
      'waiting for an owner',
      unavailable(TeamCertificateProblem.waitingForOwner),
      (l) => '${l.teamCertWaitingForOwner} ${l.teamCertOwnerCanHand} (ZS-1501)',
      true,
    ),
    // ZestSSH Cloud could not be asked.
    ('not asked: known away', const TeamCertificateNotAsked(), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('no answer', const SocketException('Connection refused'), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('no answer in time', TimeoutException('no answer'), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('the connection broke', http.ClientException('Connection closed'), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('no secure connection', const HandshakeException('bad certificate'), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('a fault, 500', const OrchardServerException(500, null), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('a fault, 503', const OrchardServerException(503, null), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    ('too many requests', const OrchardServerException(429, null), (l) => '${l.teamCertNotAsked} (ZS-1502)', true),
    // What the record has against it: no owner's device signs that either.
    ('no authority', unavailable(TeamCertificateProblem.noAuthority), (l) => l.teamCertNoAuthority, false),
    ('no access', unavailable(TeamCertificateProblem.noAccess), (l) => l.teamCertNoAccess, false),
    ('no user names', unavailable(TeamCertificateProblem.noUserNames), (l) => l.teamCertNoUserNames, false),
    (
      'not this user name',
      unavailable(TeamCertificateProblem.notThisUserName),
      (l) => l.teamCertNotThisUserName('root', 'deploy'),
      false,
    ),
    ('held back', unavailable(TeamCertificateProblem.heldBack), (l) => l.teamCertHeldBack, false),
    // What the server answered, and would not.
    ('signed out there', const OrchardServerException(401, 'signed-out'), (l) => l.orchardErrorSignedOut, false),
    ('refused by the rules', const OrchardServerException(403, 'rules-unmet'), (l) => l.teamCertHeldBack, false),
    ('refused', const OrchardServerException(403, null), (l) => l.teamCertHeldBack, false),
    ('no longer in the team', const OrchardServerException(404, null), (l) => l.teamCertHeldBack, false),
    (
      'keys the account replaced',
      const OrchardServerException(409, 'stale-account-keys'),
      (l) => l.orchardErrorKeysNotReady,
      false,
    ),
    // Keys that are not on the device, and what has no words of its own.
    ('no account keys here', const AccountKeysNotReady(), (l) => l.orchardErrorKeysNotReady, false),
    ('a fault of the app', StateError('something else'), (l) => l.teamCertFailed, false),
    ('a request the server could not read', const OrchardServerException(400, null), (l) => l.teamCertFailed, false),
  ];

  test('each thing that keeps a login from a certificate is said as what it is, in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final (what, e, said, _) in cases) {
        expect(teamCertificateFailureMessage(l10n, e, 'root'), said(l10n), reason: '$locale: $what');
      }
    }
    // The words differ where the things differ.
    final words = {for (final (_, e, _, _) in cases) teamCertificateFailureMessage(en, e, 'root')};
    expect(words, hasLength(10));
  });

  test('an owner can get around two of them, and only those end in a code', () {
    for (final (what, e, said, handed) in cases) {
      expect(teamCertificateCanBeHanded(e), handed, reason: what);
      final code = ErrorCodes.codeIn(said(en));
      expect(code != null, handed, reason: '$what: a code exactly where an owner can help');
    }
    expect(ErrorCodes.codeIn(teamCertificateFailureMessage(en, const TeamCertificateNotAsked(), 'root')),
        ErrorCodes.teamCertNotAsked);
    expect(
        ErrorCodes.codeIn(
            teamCertificateFailureMessage(en, unavailable(TeamCertificateProblem.waitingForOwner), 'root')),
        ErrorCodes.teamCertWaiting);
    // The two codes say what to do, and that it is the handover.
    for (final code in [ErrorCodes.teamCertWaiting, ErrorCodes.teamCertNotAsked]) {
      expect(ErrorCodes.all, contains(code));
      expect(code.fix.join(' '), contains('Certificate from an owner'));
    }
  });

  group('the Crate a login can be offered a certificate for', () {
    late AppDatabase db;

    Future<Identity> key(String id, {String? crate}) async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: id, label: id, username: 'root', authMethod: kTeamCertificateAuth, createdAt: DateTime(2026, 10, 1)));
      if (crate != null) {
        await db.customStatement(
            "INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', ?, ?, 1)",
            [id, crate]);
      }
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      return (await db.identitiesDao.getById(id))!;
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await db.customStatement(
          "INSERT INTO orchard_info (id, orchard_id, role, key_generation, status) VALUES (1, 'orchard-1', 'member', 0, 'active')");
    });

    tearDown(() => db.close());

    test('is the one its key is in, where an owner can get around what stopped it', () async {
      final identity = await key('k1', crate: 'crate-1');
      expect(await teamCertificateCrate(db, identity), (orchardId: 'orchard-1', crateId: 'crate-1'));

      final waiting =
          await teamCertificateFailure(en, unavailable(TeamCertificateProblem.waitingForOwner), db, identity);
      expect(waiting.message, '${en.teamCertWaitingForOwner} ${en.teamCertOwnerCanHand} (ZS-1501)');
      expect(waiting.handover, (orchardId: 'orchard-1', crateId: 'crate-1'));
      final away = await teamCertificateFailure(en, const TeamCertificateNotAsked(), db, identity);
      expect(away.message, '${en.teamCertNotAsked} (ZS-1502)');
      expect(away.handover, (orchardId: 'orchard-1', crateId: 'crate-1'));

      // What no owner's device would sign either: said, and nothing offered.
      final closed = await teamCertificateFailure(en, unavailable(TeamCertificateProblem.noAccess), db, identity);
      expect(closed.message, en.teamCertNoAccess);
      expect(closed.handover, isNull);
      final refused = await teamCertificateFailure(en, const OrchardServerException(403, 'rules-unmet'), db, identity);
      expect(refused.message, en.teamCertHeldBack);
      expect(refused.handover, isNull);
      // The user name is the key's.
      final other = await teamCertificateFailure(en, unavailable(TeamCertificateProblem.notThisUserName), db, identity);
      expect(other.message, en.teamCertNotThisUserName('root', 'deploy'));
    });

    test('is none for a key in no Crate, and none in your Tree', () async {
      final loose = await key('k2');
      expect(await teamCertificateCrate(db, loose), isNull);
      expect((await teamCertificateFailure(en, const TeamCertificateNotAsked(), db, loose)).handover, isNull);

      final tree = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(tree.close);
      await tree.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: 'k3', label: 'k3', username: 'root', authMethod: kTeamCertificateAuth, createdAt: DateTime(2026, 10, 1)));
      expect(await teamCertificateCrate(tree, (await tree.identitiesDao.getById('k3'))!), isNull);
    });
  });
}
