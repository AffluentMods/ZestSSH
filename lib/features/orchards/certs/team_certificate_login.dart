import 'package:zest_ssh_core/dartssh2.dart' show SSHKeyPair;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';

/// The auth method of a team certificate key (3.0): a key in a
/// Crate whose certificate authority is on, holding nothing secret. It
/// names the user to sign in as; each device connects with its own SSH key
/// and a certificate the Crate's authority signed for it.
const String kTeamCertificateAuth = 'teamCertificate';

/// The key pair the team certificate key [identity] (in the Orchard
/// database [db]) connects with: this device's key for the Orchard with a
/// certificate from the authority of the Crate the key is in, as
/// [Identity.username]. With [ask] false nothing is asked of the server and
/// only a certificate already on this device counts (nobody is there to
/// wait); otherwise it waits up to [wait] for an owner's device to sign one.
/// Throws [TeamCertificateUnavailable].
Future<SSHKeyPair> teamCertificateLogin(
  OrchardService service,
  AppDatabase db,
  Identity identity, {
  bool ask = true,
  Duration wait = const Duration(seconds: 20),
  void Function(String line)? onLog,
}) async {
  final crate = await teamCertificateCrate(db, identity);
  if (crate == null) throw const TeamCertificateUnavailable(TeamCertificateProblem.noAuthority);
  return service.teamCertificateKey(crate.orchardId, crate.crateId,
      userName: identity.username, ask: ask, wait: wait, onLog: onLog);
}

/// The Orchard and the Crate the team certificate key [identity] (in the
/// Orchard database [db]) gets its certificates in; null in your Tree (which
/// says of no Orchard that it is its own), and for a key that is in no
/// Crate.
Future<({String orchardId, String crateId})?> teamCertificateCrate(AppDatabase db, Identity identity) async {
  final info = await db.customSelect('SELECT orchard_id FROM orchard_info WHERE id = 1').getSingleOrNull();
  final orchardId = info?.read<String>('orchard_id');
  final crateId = await CratePlacement(db).crateOf('key', identity.id);
  return orchardId == null || crateId == null ? null : (orchardId: orchardId, crateId: crateId);
}

/// Whether the server answered [e] and would not have this device: signed
/// out there, refused, no longer in the Orchard, or with keys the account
/// has since replaced.
bool _turnedAway(OrchardServerException e) =>
    e.status == 401 || e.status == 403 || e.status == 404 || e.staleAccountKeys;

/// Whether [e], which kept a login from getting a team certificate, means
/// that ZestSSH Cloud could not be asked: nothing was asked because the app
/// knows it is not answering, or the request got no answer, a fault of the
/// service's own, or "too many requests".
bool _notAsked(Object e) =>
    e is TeamCertificateNotAsked ||
    (e is OrchardServerException && e.status == 429) ||
    cloudFailureOf(e) != null;

/// Whether an owner can get around [e], which kept a login from getting a
/// team certificate, by signing one directly (the handover): the request
/// waits for an owner, or could not be sent at all. Not what the record or
/// the server has against this device or this account: no owner's device
/// signs that either.
bool teamCertificateCanBeHanded(Object e) =>
    e is TeamCertificateUnavailable ? e.problem == TeamCertificateProblem.waitingForOwner : _notAsked(e);

/// What a login with the team certificate key [identity] (in the Orchard
/// database [db]) is left with when [e] kept it from getting a certificate:
/// what to tell the person, and, where an owner can sign one directly, the
/// Crate that takes it, for whatever shows the failure to offer that.
Future<({String message, ({String orchardId, String crateId})? handover})> teamCertificateFailure(
  AppLocalizations l10n,
  Object e,
  AppDatabase db,
  Identity identity,
) async =>
    (
      message: teamCertificateFailureMessage(l10n, e, identity.username),
      handover: teamCertificateCanBeHanded(e) ? await teamCertificateCrate(db, identity) : null,
    );

/// What to tell the person when [e] kept a login as [userName] from getting
/// a team certificate. What an owner can get around says so, and ends in
/// its code.
String teamCertificateFailureMessage(AppLocalizations l10n, Object e, String userName) {
  if (e is TeamCertificateUnavailable) {
    final said = teamCertificateMessage(l10n, e, userName);
    return e.problem == TeamCertificateProblem.waitingForOwner
        ? ErrorCodes.withCode('$said ${l10n.teamCertOwnerCanHand}', ErrorCodes.teamCertWaiting)
        : said;
  }
  if (_notAsked(e)) return ErrorCodes.withCode(l10n.teamCertNotAsked, ErrorCodes.teamCertNotAsked);
  if (e is OrchardServerException && _turnedAway(e)) {
    if (e.status == 401) return l10n.orchardErrorSignedOut;
    if (e.staleAccountKeys) return l10n.orchardErrorKeysNotReady;
    return l10n.teamCertHeldBack;
  }
  if (e is AccountKeysNotReady) return l10n.orchardErrorKeysNotReady;
  return l10n.teamCertFailed;
}

/// What to tell the person when [e] stops a connection as [userName].
String teamCertificateMessage(AppLocalizations l10n, TeamCertificateUnavailable e, String userName) =>
    switch (e.problem) {
      TeamCertificateProblem.noAuthority => l10n.teamCertNoAuthority,
      TeamCertificateProblem.noAccess => l10n.teamCertNoAccess,
      TeamCertificateProblem.noUserNames => l10n.teamCertNoUserNames,
      TeamCertificateProblem.notThisUserName => l10n.teamCertNotThisUserName(userName, e.userNames.join(', ')),
      TeamCertificateProblem.waitingForOwner => l10n.teamCertWaitingForOwner,
      TeamCertificateProblem.heldBack => l10n.teamCertHeldBack,
    };
