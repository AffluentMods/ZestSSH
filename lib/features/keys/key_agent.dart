import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/redactable.dart' show fingerprintAsShown;
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart' show Profiles;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/utils/type_name.dart';

// Add to agent (3.0, Keys): a
// key in the vault given to the system's SSH agent (the OpenSSH agent's pipe
// on Windows, SSH_AUTH_SOCK's agent on macOS and Linux) through the agent
// protocol, for a time or until the agent ends, so that ssh, git and other
// tools on the computer can sign in with it. Phones have no system agent:
// none is offered there.

/// How long the agent keeps a key given to it.
enum AgentKeyLifetime {
  /// No time limit: until the agent ends (on a Mac and on Linux, when the
  /// person signs out; Windows' agent keeps it until it is removed).
  untilAgentEnds(null),
  oneHour(Duration(hours: 1)),
  eightHours(Duration(hours: 8));

  const AgentKeyLifetime(this.lifetime);

  final Duration? lifetime;
}

/// The system's SSH agent, as the Keys page uses it.
abstract class SystemAgent {
  /// The fingerprints (SHA256, as ssh-keygen -l writes them) of the keys
  /// it holds. Throws [OsAgentException] where none can be reached.
  Future<Set<String>> fingerprints();

  /// Gives it [request] (SSHAgentProtocol.addIdentityRequest). Throws
  /// [AgentAddFailed] where it cannot be reached, [OsAgentException] where
  /// it says no.
  Future<void> add(Uint8List request);

  /// Takes back the keys with these fingerprints (as ssh-keygen -l writes them), those
  /// it holds. Throws [OsAgentException] where none can be reached.
  Future<void> remove(Set<String> fingerprints);
}

/// The agent of the system the app runs on ([OsSshAgent]).
class OsSystemAgent implements SystemAgent {
  const OsSystemAgent();

  @override
  Future<Set<String>> fingerprints() async {
    final agent = await OsSshAgent.open();
    try {
      return {
        for (final id in await agent.listIdentities())
          fingerprintAsShown(OpenSSHKeySerializer.fingerprintFromBlob(id.publicKeyBlob)),
      };
    } finally {
      await agent.close();
    }
  }

  @override
  Future<void> add(Uint8List request) async {
    final OsSshAgent agent;
    try {
      agent = await OsSshAgent.open();
    } on AgentPipeNotYours catch (e) {
      throw AgentAddFailed(AgentAddRefusal.pipeNotYours, e);
    } catch (e) {
      throw AgentAddFailed(AgentAddRefusal.noAgent, e);
    }
    try {
      await addIdentityToOsAgent(agent, request);
    } finally {
      await agent.close();
    }
  }

  @override
  Future<void> remove(Set<String> fingerprints) async {
    final agent = await OsSshAgent.open();
    try {
      for (final id in await agent.listIdentities()) {
        if (fingerprints.contains(fingerprintAsShown(OpenSSHKeySerializer.fingerprintFromBlob(id.publicKeyBlob)))) {
          await removeIdentityFromOsAgent(agent, id.publicKeyBlob);
        }
      }
    } finally {
      await agent.close();
    }
  }
}

/// What this profile gave the system's agent, by fingerprint, in its own database:
/// its public half only, and never synced or in a backup (LocalStateStore).
const _keptGivenToAgent = 'agent_keys_given_v1';

/// [key] is in the agent because this profile gave it: noted, so that it can be taken
/// back at a change of profile, also after the app was started again, as a key given
/// until the agent ends outlasts the app. One in [heldBefore], what the agent held before
/// it was given, is the person's own (ssh-add): the agent holds it once, so taking it
/// back would take theirs, and it is not noted.
Future<void> noteGivenToAgent(LocalStateStore store, Identity key, {Set<String> heldBefore = const {}}) async {
  final print = fingerprintAsShown(key.publicKeyFingerprint?.trim() ?? '');
  if (print.isEmpty || heldBefore.contains(print)) return;
  final given = {...await _givenToAgent(store), print};
  await store.write(_keptGivenToAgent, jsonEncode(given.toList()));
  await _writeNoteFile(_noteFile(), {...await _givenInFile(_noteFile()), ...given});
}

/// The note's copy beside the database, in the profile's own folder: the
/// fingerprints alone. It is read where the database is closed, the app locked
/// when an account signs out, so that the keys still go (found in a security
/// review). None where no profile is open.
File? _noteFile() {
  final profile = Profiles.current;
  return profile == null ? null : File(p.join(profile.dir.path, '$_keptGivenToAgent.json'));
}

Future<Set<String>> _givenInFile(File? file) async {
  if (file == null || !await file.exists()) return {};
  try {
    return {for (final f in jsonDecode(await file.readAsString()) as List) f as String};
  } catch (_) {
    return {};
  }
}

Future<void> _writeNoteFile(File? file, Set<String> prints) async {
  if (file == null) return;
  try {
    if (prints.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(prints.toList()), flush: true);
  } catch (e) {
    AppLogger.warning('The note of the keys given to the system agent was not copied (${errorKind(e)})');
  }
}

Future<Set<String>> _givenToAgent(LocalStateStore store) async {
  final raw = await store.read(_keptGivenToAgent);
  if (raw == null) return {};
  try {
    return {for (final p in jsonDecode(raw) as List) p as String};
  } catch (_) {
    return {};
  }
}

/// A profile closes for another person's: the keys it gave the system's agent go, as
/// they sign in to that person's servers from any tool on this computer, and with them
/// whatever the computer's list says is owed ([agentKeysOwedName], with [keychain]).
/// Where no agent can be reached the note stays, for the next change, and goes on the
/// computer's list too; nothing else depends on this. True where none is left to take
/// back, as far as the agent said.
Future<bool> takeBackAgentKeys(SystemAgent? agent, AppDatabase? db, {FlutterSecureStorage? keychain}) async {
  if (agent == null) return true;
  var noted = <String>{};
  try {
    // With the database closed (the app locked), its copy in the profile's folder says
    // which they are.
    final store = db == null ? null : LocalStateStore(db);
    final file = _noteFile();
    noted = {if (store != null) ...await _givenToAgent(store), ...await _givenInFile(file)};
    final given = {...noted, if (keychain != null) ...(await _owedIn(keychain)).keys};
    if (given.isEmpty) return true;
    // An agent that does not answer never stands in the way of a change of profile.
    await agent.remove(given).timeout(const Duration(seconds: 3));
    if (store != null) await store.write(_keptGivenToAgent, '[]');
    await _writeNoteFile(file, const {});
    if (keychain != null) await _paid(keychain, given);
    return true;
  } catch (e) {
    AppLogger.warning('Keys given to the system agent were left there for now (${errorKind(e)})');
    // The profile's note may go with it before the next change (Remove from this
    // computer, Delete all local data), or never be on screen again.
    if (keychain != null && noted.isNotEmpty) {
      try {
        await _owe(keychain, noted, Profiles.current?.id ?? '');
      } catch (e) {
        AppLogger.warning('Keys owed back by the system agent were not listed (${errorKind(e)})');
      }
    }
    return false;
  }
}

/// The computer's own list of the keys given to the system's agent and not yet taken
/// back: each fingerprint with the id of the profile that gave it, and nothing else. Kept
/// with the app lock's names, outside every profile (KeychainNames.deviceNames), and
/// written before a key is given. A profile's own note is written after the give, goes
/// with its database and folder, and is read only while that profile is on screen: a key
/// whose take-back failed, of a profile then removed, wiped or never opened again, or one
/// a stop left un-noted, stayed in the agent for the next person on the computer's login
/// (found in an independent review). What it lists goes back at each
/// change of profile, and at each opening for every profile but the one opened
/// ([settleAgentKeysAtOpening]).
const agentKeysOwedName = 'agent_keys_owed_v1';

Future<Map<String, String>> _owedIn(FlutterSecureStorage keychain) async {
  final raw = await keychain.read(key: agentKeysOwedName);
  if (raw == null) return {};
  try {
    return {for (final e in (jsonDecode(raw) as Map).entries) e.key as String: e.value as String};
  } catch (_) {
    return {};
  }
}

Future<void> _keepOwed(FlutterSecureStorage keychain, Map<String, String> owed) => owed.isEmpty
    ? keychain.delete(key: agentKeysOwedName)
    : keychain.write(key: agentKeysOwedName, value: jsonEncode(owed));

/// [prints] are owed back as [profile]'s: those that were not already, which it returns.
Future<Set<String>> _owe(FlutterSecureStorage keychain, Iterable<String> prints, String profile) async {
  final owed = await _owedIn(keychain);
  final added = {for (final p in prints) if (!owed.containsKey(p)) p};
  if (added.isEmpty) return added;
  for (final p in added) {
    owed[p] = profile;
  }
  await _keepOwed(keychain, owed);
  return added;
}

/// [prints] are back: off the list.
Future<void> _paid(FlutterSecureStorage keychain, Set<String> prints) async {
  final owed = await _owedIn(keychain);
  final before = owed.length;
  owed.removeWhere((p, _) => prints.contains(p));
  if (owed.length != before) await _keepOwed(keychain, owed);
}

/// What the note in [folder] says the profile [profile] gave the system's agent goes on
/// the computer's list: read before that folder goes (Remove from this computer, Delete
/// all local data's Everything).
Future<void> oweWhatIsNotedIn(FlutterSecureStorage keychain, String profile, Directory folder) async {
  final noted = await _givenInFile(File(p.join(folder.path, '$_keptGivenToAgent.json')));
  if (noted.isNotEmpty) await _owe(keychain, noted, profile);
}

/// What the computer's list says is owed by any profile but [except] goes back now, but
/// for [keep]. Where no agent answers, it stays listed for the next opening or change.
Future<void> takeBackOwedAgentKeys(SystemAgent? agent, FlutterSecureStorage keychain,
    {String? except, Set<String> keep = const {}}) async {
  if (agent == null) return;
  try {
    final owed = await _owedIn(keychain);
    final back = {
      for (final e in owed.entries)
        if (e.value != except && !keep.contains(e.key)) e.key,
    };
    if (back.isEmpty) return;
    await agent.remove(back).timeout(const Duration(seconds: 3));
    await _paid(keychain, back);
  } catch (e) {
    AppLogger.warning('Keys owed back by the system agent were left there for now (${errorKind(e)})');
  }
}

/// A profile has opened (a start, an unlock, a change): what other profiles still owe
/// goes back ([takeBackOwedAgentKeys]), and this one's keys stay. What its database notes
/// that its folder does not, from before the note was kept beside it, is copied there and
/// onto the computer's list, so that a sign-out with the app locked still finds it (found
/// in a review).
Future<void> settleAgentKeysAtOpening(SystemAgent? agent, AppDatabase? db, FlutterSecureStorage keychain) async {
  if (agent == null) return;
  final here = Profiles.current?.id;
  var mine = <String>{};
  try {
    final file = _noteFile();
    final inFile = await _givenInFile(file);
    final noted = db == null ? const <String>{} : await _givenToAgent(LocalStateStore(db));
    mine = {...inFile, ...noted};
    if (!inFile.containsAll(noted)) await _writeNoteFile(file, mine);
    if (noted.isNotEmpty) await _owe(keychain, noted, here ?? '');
  } catch (e) {
    AppLogger.warning('The note of the keys given to the system agent was not copied (${errorKind(e)})');
  }
  await takeBackOwedAgentKeys(agent, keychain, except: here, keep: mine);
}

/// Whether the device has a system agent to offer: a computer. Never under
/// `flutter test` (FLUTTER_TEST), which must not reach the agent of the
/// computer the tests run on: a test gives its own ([systemAgentProvider]).
bool get deviceHasSystemAgent =>
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux) && !Platform.environment.containsKey('FLUTTER_TEST');

/// The system agent, or null on a phone.
final systemAgentProvider = Provider<SystemAgent?>((ref) => deviceHasSystemAgent ? const OsSystemAgent() : null);

/// The fingerprints of the keys the system agent holds now: none where
/// there is no agent, or it cannot be reached. Read again when the Keys
/// page is opened, and after a key is added.
final systemAgentKeysProvider = FutureProvider.autoDispose<Set<String>>((ref) async {
  final agent = ref.watch(systemAgentProvider);
  if (agent == null) return const <String>{};
  try {
    return await agent.fingerprints();
  } catch (_) {
    return const <String>{};
  }
});

/// Whether [key] is one the system agent holds ([inAgent], its
/// fingerprints).
bool keyIsInSystemAgent(Identity key, Set<String> inAgent) {
  final fp = fingerprintAsShown(key.publicKeyFingerprint?.trim() ?? '');
  return fp.isNotEmpty && inAgent.contains(fp);
}

/// Whether [key] may be given to the system agent: a key whose private key
/// the vault holds.
bool canAddToSystemAgent(Identity key) => key.authMethod == 'publicKey' && !key.usesAgent;

/// What could not be added, said by its kind.
enum AgentAddRefusal {
  /// No agent runs, or it could not be reached.
  noAgent,

  /// On Windows, the agent's pipe is served by another account's program,
  /// or by one Windows would not name ([AgentPipeNotYours]): the key was not
  /// sent.
  pipeNotYours,

  /// The agent said no (for a time limit, an agent that keeps keys without
  /// one: Windows').
  refused,

  /// The key is sealed under a passphrase that was not given.
  needsPassphrase,

  /// The passphrase given does not open it.
  wrongPassphrase,

  /// The private key is not there, or is no key an agent takes.
  noKey,
}

class AgentAddFailed implements Exception, HasTypeName {
  const AgentAddFailed(this.why, [this.cause]);

  final AgentAddRefusal why;
  final Object? cause;

  @override
  String get typeName => 'AgentAddFailed';

  @override
  String toString() => 'AgentAddFailed(${why.name}${cause == null ? '' : ': $cause'})';
}

/// [addKeyToAgent], noted as this profile's to take back ([noteGivenToAgent]) only where
/// the agent did not hold [key] already. An agent that cannot say what it holds is taken
/// to hold nothing: a key left behind for the next person is worse than one added again.
Future<void> giveKeyToAgent(
  SystemAgent agent,
  LocalStateStore store,
  Identity key,
  String? pem, {
  String? passphrase,
  AgentKeyLifetime lifetime = AgentKeyLifetime.untilAgentEnds,
  FlutterSecureStorage? keychain,
}) async {
  var heldBefore = const <String>{};
  try {
    heldBefore = await agent.fingerprints().timeout(const Duration(seconds: 3));
  } catch (e) {
    AppLogger.warning('What the system agent holds was not read (${errorKind(e)})');
  }
  // On the computer's list before the agent has it: a stop between the two leaves it
  // said ([agentKeysOwedName]).
  final print = fingerprintAsShown(key.publicKeyFingerprint?.trim() ?? '');
  final listed = keychain == null || print.isEmpty || heldBefore.contains(print)
      ? const <String>{}
      : await _owe(keychain, {print}, Profiles.current?.id ?? '');
  try {
    await addKeyToAgent(agent, key, pem, passphrase: passphrase, lifetime: lifetime);
  } catch (_) {
    if (keychain != null && listed.isNotEmpty) await _paid(keychain, listed);
    rethrow;
  }
  await noteGivenToAgent(store, key, heldBefore: heldBefore);
}

/// Gives [pem] (the private key of [key], opened with [passphrase] where it
/// is sealed) to [agent], named as the key is, kept for [lifetime].
Future<void> addKeyToAgent(
  SystemAgent agent,
  Identity key,
  String? pem, {
  String? passphrase,
  AgentKeyLifetime lifetime = AgentKeyLifetime.untilAgentEnds,
}) async {
  if (pem == null || pem.isEmpty) throw const AgentAddFailed(AgentAddRefusal.noKey);
  final List<SSHKeyPair> pairs;
  try {
    final sealed = SSHKeyPair.isEncryptedPem(pem);
    if (sealed && (passphrase == null || passphrase.isEmpty)) {
      throw const AgentAddFailed(AgentAddRefusal.needsPassphrase);
    }
    pairs = SSHKeyPair.fromPem(pem, sealed ? passphrase : null);
  } on AgentAddFailed {
    rethrow;
  } on SSHKeyDecryptError catch (e) {
    throw AgentAddFailed(AgentAddRefusal.wrongPassphrase, e);
  } on SSHKeyDecodeError catch (e) {
    throw AgentAddFailed(AgentAddRefusal.wrongPassphrase, e);
  } catch (e) {
    throw AgentAddFailed(AgentAddRefusal.noKey, e);
  }
  if (pairs.isEmpty) throw const AgentAddFailed(AgentAddRefusal.noKey);
  final Uint8List request;
  try {
    request = SSHAgentProtocol.addIdentityRequest(pairs.first, comment: key.label, lifetime: lifetime.lifetime);
  } catch (e) {
    throw AgentAddFailed(AgentAddRefusal.noKey, e);
  }
  try {
    await agent.add(request);
  } on AgentAddFailed {
    rethrow;
  } on OsAgentException catch (e) {
    throw AgentAddFailed(AgentAddRefusal.refused, e);
  } catch (e) {
    throw AgentAddFailed(AgentAddRefusal.noAgent, e);
  }
}
