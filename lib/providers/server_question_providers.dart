import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/utils/logger.dart';

/// A server's sign-in question waiting for the person (keyboard-interactive:
/// a one-time code, a new password), with the connection it belongs to.
class ServerQuestionRequest {
  ServerQuestionRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.question,
  });

  final String host;
  final int port;
  final String username;
  final ServerQuestion question;

  final _answer = Completer<List<String>?>();

  /// The person's answers, one per prompt, or null when cancelled or no
  /// longer wanted.
  Future<List<String>?> get answer => _answer.future;

  /// False once answered, cancelled or withdrawn.
  bool get isOpen => !_answer.isCompleted;

  void reply(List<String> answers) {
    if (isOpen) _answer.complete(List.unmodifiable(answers));
  }

  void cancel() {
    if (isOpen) _answer.complete(null);
  }
}

/// Server questions waiting to be shown, oldest first. Connections opened
/// together (a workspace) can all ask at once; the UI shows one at a time and
/// nothing is dropped.
class ServerQuestionQueue extends StateNotifier<List<ServerQuestionRequest>> {
  ServerQuestionQueue() : super(const []);

  ServerQuestionRequest? get current => state.isEmpty ? null : state.first;

  void add(ServerQuestionRequest request) {
    state = [...state, request];
  }

  /// Idempotent: removing a request that is already gone does nothing.
  void remove(ServerQuestionRequest request) {
    if (!state.any((r) => identical(r, request))) return;
    state = state.where((r) => !identical(r, request)).toList();
  }
}

final serverQuestionQueueProvider =
    StateNotifierProvider<ServerQuestionQueue, List<ServerQuestionRequest>>(
  (ref) => ServerQuestionQueue(),
);

/// The question the UI should be showing now: the head of the queue.
final serverQuestionProvider = Provider<ServerQuestionRequest?>((ref) {
  final queue = ref.watch(serverQuestionQueueProvider);
  return queue.isEmpty ? null : queue.first;
});

/// How long a question waits for an answer before the sign-in gives up, for
/// when nothing is on screen to show it. The server's own login time limit
/// is usually shorter and ends it first.
const kServerQuestionTimeout = Duration(minutes: 3);

/// An asker that puts questions for [username]@[host] in front of the person
/// through [serverQuestionQueueProvider].
ServerQuestionAsker serverQuestionAsker(
  Ref ref, {
  required String host,
  required int port,
  required String username,
}) {
  return (question) async {
    final request = ServerQuestionRequest(
      host: host,
      port: port,
      username: username,
      question: question,
    );
    final queue = ref.read(serverQuestionQueueProvider.notifier);
    queue.add(request);
    unawaited(question.withdrawn.then((_) => request.cancel()));
    try {
      return await request.answer.timeout(kServerQuestionTimeout,
          onTimeout: () {
        AppLogger.warning('Server question for $host:$port was not answered '
            'in time');
        request.cancel();
        return null;
      });
    } finally {
      queue.remove(request);
    }
  };
}

/// What a sign-in that waits on a login banner's link is for: what its
/// notice says goes on once the person is done there.
enum SignInNoticeFor {
  /// A session (a terminal, or files only): it opens.
  session,

  /// A run on the host (Run on hosts, an automation task its person
  /// started): it goes on.
  run,

  /// A host's connection test: it goes on.
  test,
}

/// A login banner with a link that a sign-in waits on ([SignInNotice]:
/// Tailscale SSH's "check" mode), shown to the person until the sign-in is
/// over or they cancel it.
class SignInNoticeRequest {
  SignInNoticeRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.notice,
    this.jumpHost,
    this.onward,
    this.purpose = SignInNoticeFor.session,
  }) {
    unawaited(notice.withdrawn.then((_) => _finish(false)));
  }

  final String host;
  final int port;
  final String username;
  final SignInNotice notice;

  /// Where the sign-in is a jump host's on the way: what that jump host is
  /// called, and the host it is on the way to ([onward]). Null for the
  /// host itself.
  final String? jumpHost;
  final String? onward;

  /// What waits on the sign-in.
  final SignInNoticeFor purpose;

  final _cancelled = Completer<bool>();

  /// True where the person cancelled the sign-in, false where it was over
  /// first.
  Future<bool> get cancelled => _cancelled.future;

  /// False once cancelled or withdrawn.
  bool get isOpen => !_cancelled.isCompleted;

  /// The person cancels the sign-in.
  void cancel() => _finish(true);

  void _finish(bool cancelled) {
    if (isOpen) _cancelled.complete(cancelled);
  }
}

/// Login banners with a link waiting to be shown, oldest first.
class SignInNoticeQueue extends StateNotifier<List<SignInNoticeRequest>> {
  SignInNoticeQueue() : super(const []);

  void add(SignInNoticeRequest request) {
    state = [...state, request];
  }

  /// Idempotent: removing a request that is already gone does nothing.
  void remove(SignInNoticeRequest request) {
    if (!state.any((r) => identical(r, request))) return;
    state = state.where((r) => !identical(r, request)).toList();
  }
}

final signInNoticeQueueProvider =
    StateNotifierProvider<SignInNoticeQueue, List<SignInNoticeRequest>>(
  (ref) => SignInNoticeQueue(),
);

/// The login banner the UI should be showing now: the head of the queue.
final signInNoticeProvider = Provider<SignInNoticeRequest?>((ref) {
  final queue = ref.watch(signInNoticeQueueProvider);
  return queue.isEmpty ? null : queue.first;
});

/// A shower that puts login banners with a link for [username]@[host] in
/// front of the person through [signInNoticeQueueProvider]. The sign-in's
/// own clock ([kSignInLinkPatience]) says how long it waits. [jumpHost] and
/// [onward] name a jump host on the way and where it leads; [purpose] is
/// what waits on the sign-in.
SignInNoticeShower signInNoticeShower(
  Ref ref, {
  required String host,
  required int port,
  required String username,
  String? jumpHost,
  String? onward,
  SignInNoticeFor purpose = SignInNoticeFor.session,
}) {
  return (notice) async {
    final request = SignInNoticeRequest(
      host: host,
      port: port,
      username: username,
      notice: notice,
      jumpHost: jumpHost,
      onward: onward,
      purpose: purpose,
    );
    final queue = ref.read(signInNoticeQueueProvider.notifier);
    queue.add(request);
    try {
      return await request.cancelled;
    } finally {
      queue.remove(request);
    }
  };
}
