import 'package:zestssh/utils/type_name.dart';

/// What was being done at a jump host when it failed.
enum JumpStage {
  /// Its sign-in details were being loaded (its key, its password).
  details,

  /// It was being reached.
  reach,

  /// It was being signed in to.
  signIn,

  /// It was asked to open the way on, to the next jump host or to the host.
  onward,
}

/// A jump host on the way to a host failed. What it failed with was handed
/// on as it came and said as the host's own failure, with the host's
/// address in the words: "db-primary is not accepting connections" of a
/// jump host that was down.
class JumpHostFailure implements Exception, HasTypeName {
  const JumpHostFailure({
    required this.label,
    required this.host,
    required this.port,
    this.username,
    required this.stage,
    required this.cause,
    this.onward,
  });

  /// The jump host: its name, and where it is.
  final String label;
  final String host;
  final int port;
  final String? username;

  final JumpStage stage;

  /// What it failed with.
  final Object cause;

  /// What it was to open the way to ([JumpStage.onward]): the name of the
  /// next jump host, or of the host.
  final String? onward;

  @override
  String toString() => 'Jump host $label (${stage.name}): $cause';

  @override
  String get typeName => 'JumpHostFailure';
}

/// The connection to a jump host that had been signed in to ended by itself
/// while the host behind it (the next jump host, or the host) was being
/// connected to through it. The way went with it, and what connecting on
/// failed with then ([during]) says no more than that its line closed: it
/// was said as the failure of the host behind ("the server closed the
/// connection before the sign-in was over"), whatever had ended the
/// connection to the jump host.
class JumpHostEndedOnTheWay implements Exception, HasTypeName {
  const JumpHostEndedOnTheWay({required this.label, this.cause, required this.during});

  /// The jump host, as the app names it.
  final String label;

  /// What its connection ended with; null where it was closed with nothing
  /// said.
  final Object? cause;

  /// What connecting to the host behind it failed with meanwhile.
  final Object during;

  @override
  String toString() => 'The connection to the jump host $label ended '
      '(${cause ?? 'closed, with nothing said'}) while the host behind it was being connected to: $during';

  @override
  String get typeName => 'JumpHostEndedOnTheWay';
}

/// The jump hosts a host is set to connect through cannot be followed: one
/// of them is no longer there, or they lead back to one that was on the way
/// already. Nothing was dialled, and only its person can mend it, in the
/// host's own settings or in a network's: [message] is the app's own words
/// for which it is and what to do. (It was an error with an English
/// sentence in it, which every screen showed as "An unexpected error
/// occurred while connecting".)
class JumpChainBroken implements Exception, HasTypeName {
  const JumpChainBroken(this.message);

  final String message;

  @override
  String toString() => message;

  @override
  String get typeName => 'JumpChainBroken';
}
