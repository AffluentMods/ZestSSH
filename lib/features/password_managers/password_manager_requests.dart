import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_approvals.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/utils/host_address.dart';

// What connecting with a password from the person's password manager asks of
// them (3.0), and the path that asks it. A session has no screen of
// its own: its questions wait in [passwordManagerRequestProvider] and the
// app answers them on screen, one at a time.

/// A question for the person, answered once.
sealed class PasswordManagerRequest<T> {
  PasswordManagerRequest({required this.kind});

  /// The password manager it is about.
  final PasswordManagerKind kind;

  final _answer = Completer<T>();

  Future<T> get answer => _answer.future;

  bool get isOpen => !_answer.isCompleted;

  void reply(T value) {
    if (isOpen) _answer.complete(value);
  }
}

/// Bitwarden's master password or KeePassXC's database password, to unlock
/// it for this run; [again] after a wrong one. Null: cancelled.
class PmUnlockRequest extends PasswordManagerRequest<String?> {
  PmUnlockRequest({required super.kind, required this.again});

  final bool again;
}

/// Whether the password of [item] may go to [destination]
/// (`user@host:port`), asked the first time on this device for a key others
/// can change.
class PmApprovalRequest extends PasswordManagerRequest<bool> {
  PmApprovalRequest({required super.kind, required this.item, required this.destination});

  final PasswordRefDescription item;
  final String destination;
}

/// The password could not be fetched ([failure], and what the tool said in
/// [details]), or this device has no tools to fetch it with ([failure] null,
/// a phone): the person may type it this once. Null: stop.
class PmTypeOnceRequest extends PasswordManagerRequest<String?> {
  PmTypeOnceRequest({required super.kind, required this.destination, this.failure, this.details});

  final String destination;
  final PmFailure? failure;
  final String? details;
}

/// The question waiting for the person, if any.
final passwordManagerRequestProvider = StateProvider<PasswordManagerRequest<Object?>?>((ref) => null);

/// How long a question waits: nothing answering counts as no.
const kPasswordManagerRequestTimeout = Duration(minutes: 2);

/// Something that can read providers: a provider's `Ref` or a screen's
/// `WidgetRef`.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Puts [request] to the person, after any question already open, and
/// waits for the answer; [onTimeout] when none comes in time.
Future<T> askPasswordManager<T>(ProviderRead read, PasswordManagerRequest<T> request, {required T onTimeout}) async {
  while (true) {
    final open = read(passwordManagerRequestProvider);
    if (open == null || !open.isOpen) break;
    try {
      await open.answer;
    } catch (_) {}
  }
  final controller = read(passwordManagerRequestProvider.notifier);
  controller.state = request as PasswordManagerRequest<Object?>;
  try {
    return await request.answer.timeout(kPasswordManagerRequestTimeout, onTimeout: () {
      AppLogger.warning('Password managers: nobody answered in time');
      request.reply(onTimeout);
      return onTimeout;
    });
  } finally {
    if (identical(controller.state, request)) controller.state = null;
  }
}

/// What the connect path asks: on screen in the app ([PromptedAsker]), a
/// stand-in in tests.
abstract class PasswordManagerAsker {
  Future<String?> unlock(PasswordManagerKind kind, {required bool again});
  Future<bool> approve(PasswordManagerKind kind, PasswordRefDescription item, String destination);
  Future<String?> typeOnce(PasswordManagerKind kind, String destination, {PmFailure? failure, String? details});
}

/// Asks through [passwordManagerRequestProvider].
class PromptedAsker implements PasswordManagerAsker {
  const PromptedAsker(this._read);

  final ProviderRead _read;

  @override
  Future<String?> unlock(PasswordManagerKind kind, {required bool again}) =>
      askPasswordManager(_read, PmUnlockRequest(kind: kind, again: again), onTimeout: null);

  @override
  Future<bool> approve(PasswordManagerKind kind, PasswordRefDescription item, String destination) =>
      askPasswordManager(_read, PmApprovalRequest(kind: kind, item: item, destination: destination), onTimeout: false);

  @override
  Future<String?> typeOnce(PasswordManagerKind kind, String destination, {PmFailure? failure, String? details}) =>
      askPasswordManager(_read,
          PmTypeOnceRequest(kind: kind, destination: destination, failure: failure, details: details),
          onTimeout: null);
}

/// Asks nobody: a run with nobody there (automation) stops at the first
/// question instead, with what [stopped] makes. A password manager that is
/// unlocked, and already allowed for the address, answers with no question,
/// so such a run still gets its password. (An unattended run put "type the
/// password" or "allow this password to go to ..." on the screen of whoever
/// held the device and waited two minutes for an answer: found in a security
/// review.)
class NobodyToAsk implements PasswordManagerAsker {
  const NobodyToAsk(this.stopped);

  final Object Function() stopped;

  @override
  Future<String?> unlock(PasswordManagerKind kind, {required bool again}) => Future.error(stopped());

  @override
  Future<bool> approve(PasswordManagerKind kind, PasswordRefDescription item, String destination) =>
      Future.error(stopped());

  @override
  Future<String?> typeOnce(PasswordManagerKind kind, String destination, {PmFailure? failure, String? details}) =>
      Future.error(stopped());
}

/// A key's reference cannot be read (missing, or not a valid reference).
class PasswordRefMissing implements Exception, HasTypeName {
  const PasswordRefMissing();

  @override
  String get typeName => 'PasswordRefMissing';

  @override
  String toString() => typeName;
}

/// The person did not allow the password to go where it was going.
class PasswordRefNotAllowed implements Exception, HasTypeName {
  const PasswordRefNotAllowed();

  @override
  String get typeName => 'PasswordRefNotAllowed';

  @override
  String toString() => typeName;
}

/// The password of [identity], a 'passwordManager' key in [db], going to
/// [username]@[host]:[port] (3.0): fetched from the person's
/// password manager with [managers] and never kept, after their yes the
/// first time on this device when others can change the key or the host.
/// When it cannot be fetched, or [managers] is null (a phone), the person
/// may type it this once. Null when they stop.
Future<String?> managedPassword(
  AppDatabase db,
  Identity identity, {
  required String username,
  required String host,
  required int port,
  required PasswordManagers? managers,
  required PasswordManagerAsker asker,
  void Function(String line)? onLog,
}) async {
  final ref = PasswordRef.decode(identity.passwordRef);
  if (ref == null) throw const PasswordRefMissing();
  final destination = '$username@${hostWithPort(host, port)}';
  if (managers == null) {
    onLog?.call('identity: The password is in a password manager; asking for it (it is not kept)');
    return asker.typeOnce(ref.kind, destination);
  }
  try {
    final allowed = await allowPasswordRefUse(db,
        identityId: identity.id,
        ref: ref,
        username: username,
        host: host,
        port: port,
        ask: () async => asker.approve(ref.kind, await managers.describe(ref, ask: asker.unlock), destination));
    if (!allowed) throw const PasswordRefNotAllowed();
    onLog?.call('identity: Fetching the password from ${ref.kind.code}...');
    final password = await managers.fetch(ref, ask: asker.unlock);
    onLog?.call('identity: Password fetched; it is used once and not kept');
    return password;
  } on PasswordManagerException catch (e) {
    onLog?.call('identity: The password manager did not give the password (${e.failure.name})');
    // Stopped in the password manager, or in an unlock: stop here too.
    if (e.failure == PmFailure.cancelled) return null;
    return asker.typeOnce(ref.kind, destination, failure: e.failure, details: e.details);
  }
}
