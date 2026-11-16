import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart' show AgentSignInAborted;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_service.dart' show hostRefusedSignIn;

/// Whether connecting again by itself cannot help after a try ended with
/// [error]: the host refused the sign-in, or ended the connection while it
/// was being signed in to and said that it does ([hostRefusedSignIn]), its
/// key was not accepted, it named a group for the key exchange that is not
/// taken, it broke the order of the strict key exchange, or it has no
/// algorithm of one kind in common with what it was offered. The next try
/// would end the same way, and each one is another refused sign-in, or
/// another connection that ended before sign-in, in the host's log: ten of
/// them in three minutes is what gets an address banned.
/// Anything else is worth the next try: the network, a
/// host that is starting, a time-out, and a reason of the app's own (a
/// certificate not signed yet, say), which reaches no host and may be gone
/// by then.
///
/// A session that dropped is not connected to again after such a try, and
/// Server Monitor does not dial such a host again by its timer.
bool reconnectCannotHelp(Object error) {
  // A remote screen's (4.0): its password, its security, its certificate,
  // forwarding its SSH host refuses, a carrier that is gone, or a server
  // that ended the session: the person, or a change on a server, first.
  if (error is ScreenFailure) return error.reconnectCannotHelp;
  // What a jump host failed with counts as it would for the host itself.
  if (error is JumpHostFailure) return reconnectCannotHelp(error.cause);
  // So does what ended the connection to a jump host while the host behind
  // it was being connected to: a key that failed when new keys were taken
  // is not tried again by itself, and a jump host that closed its
  // connection, or said why it ended it, may be there for the next try.
  if (error is JumpHostEndedOnTheWay) {
    final cause = error.cause;
    return cause != null && reconnectCannotHelp(cause);
  }
  return hostRefusedSignIn(error) ||
      error is SSHHostkeyError ||
      (error is SSHAuthAbortError && error.reason is SSHHostkeyError) ||
      // A group the host named for the key exchange and that is not taken:
      // the next try would be named the same one.
      error is SSHKexGroupError ||
      (error is SSHAuthAbortError && error.reason is SSHKexGroupError) ||
      // A host that broke the order of the strict key exchange breaks it
      // again, and so does whoever is on the line.
      _strictOrderBroken(error) ||
      (error is SSHAuthAbortError && _strictOrderBroken(error.reason)) ||
      // A host that has no algorithm of one kind in common with what was
      // offered is offered the same by the next try, and offers the same.
      _nothingInCommon(error) ||
      (error is SSHAuthAbortError && _nothingInCommon(error.reason)) ||
      // A host that went quiet before its part of the key exchange is
      // offered the same by the next try: what inspects SSH on the way
      // drops it the same.
      _kexUnanswered(error) ||
      (error is SSHAuthAbortError && _kexUnanswered(error.reason)) ||
      // An agent or a hardware key that did not sign will not sign the next
      // try either, with nobody there to touch it; and each try is a
      // connection that ends before its sign-in.
      error is AgentSignInAborted ||
      // Nor will a key that could not make a signature of its own.
      error is SSHKeySignError ||
      (error is SSHAuthAbortError && error.reason is SSHKeySignError);
}

bool _strictOrderBroken(Object? error) => error is SSHHandshakeError && error.strictOrderBroken;

bool _nothingInCommon(Object? error) => error is SSHHandshakeError && error.nothingInCommon;

bool _kexUnanswered(Object? error) => error is SSHHandshakeError && error.kexUnanswered;
