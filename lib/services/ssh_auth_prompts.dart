// Shared credential-prompt rule for SSH keyboard-interactive auth.
//
// This is the SINGLE definition of "is this prompt a real password prompt?"
// used by EVERY keyboard-interactive answerer: the in-isolate SshService auth
// path, the worker-hosted SshCallbackRouter (Design B), and the jump-host,
// serial, and automation paths. Keeping it in one place is a security
// requirement, not a convenience: the rule is what stops the account password
// from being sent to a 2FA/OTP prompt, and copies DID silently drift - the
// jump and serial paths used to answer a "passcode" prompt with the password.
//
// The paths share more than the rule: they all answer through one
// [KeyboardInteractiveAnswerer], so what goes to the server, what goes to the
// person, and what fails closed is decided in one place too.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// Anchored match for a genuine password prompt.
///
/// Deliberately tight so 2FA/OTP prompts ("passcode", "verification code",
/// "one-time code") do NOT match and never receive the account password.
/// Matches e.g. "Password:", "user's password:".
final RegExp _kPasswordPromptPattern =
    RegExp(r"^(password|.*'s password)\s*:?\s*$");

/// True only for a prompt that is (a) non-echoed (real password fields never
/// echo) AND (b) tightly matches [_kPasswordPromptPattern].
///
/// Everything else - 2FA codes, verification prompts, echoed fields - fails
/// closed (returns false) so the account password is never leaked into a
/// server-controlled prompt (and, on a failed second factor, into the server's
/// 2FA/OTP auth log).
bool isRealPasswordPrompt(String promptText, {required bool echo}) {
  if (echo) return false;
  // A real password prompt is short. Cap the length so a server cannot feed a
  // multi-kilobyte prompt into the regex's backtracking tail and stall the main
  // isolate; a prompt this long is never a genuine password field. Fail closed.
  if (promptText.length > 256) return false;
  return _kPasswordPromptPattern.hasMatch(promptText.trim().toLowerCase());
}

/// How long a server may stay silent once it has started asking questions.
/// A server that has sent a question or a message may be waiting on
/// something outside the connection, such as a push approval on a phone, so
/// the usual 15 seconds is far too short. OpenSSH's own login time limit is
/// 120 seconds.
const kServerQuestionPatience = Duration(seconds: 120);

/// Longest server text shown for each part of a question.
const kServerQuestionNameMax = 128;
const kServerQuestionInstructionMax = 2000;
const kServerPromptMax = 256;

/// One question in a server's keyboard-interactive request, cleaned for
/// display. [echo] false means the answer is a secret and is shown as dots.
class ServerPrompt {
  const ServerPrompt(this.text, {required this.echo});

  final String text;
  final bool echo;
}

/// What a server asked, for the person to answer. Everything in it came from
/// the server, so the app presents it as the server's words and never fills
/// anything in.
class ServerQuestion {
  ServerQuestion({
    required this.name,
    required this.instruction,
    required this.prompts,
    required this.round,
    required this.withdrawn,
  });

  /// The server's title for the question, often empty.
  final String name;

  /// The server's explanation, often empty. May span lines.
  final String instruction;

  /// The questions that need the person, in order. Never empty.
  final List<ServerPrompt> prompts;

  /// Which keyboard-interactive round of this sign-in this is, from 1.
  final int round;

  /// Completes when the answer is no longer wanted: the sign-in finished or
  /// the connection closed. Whatever is showing the question closes itself.
  final Future<void> withdrawn;
}

/// Asks the person. Returns one answer per prompt, in order, or null when
/// they cancel.
typedef ServerQuestionAsker = Future<List<String>?> Function(
    ServerQuestion question);

/// The person cancelled a server's question, which ends that sign-in. The
/// connection flow treats it like cancelling any other connect prompt.
class SshPromptCancelled implements Exception, HasTypeName {
  const SshPromptCancelled();

  @override
  String toString() => 'Sign-in cancelled at the server\'s question';

  @override
  String get typeName => 'SshPromptCancelled';
}

/// Server text made safe to show: no control characters (a line break
/// survives only where [multiline]), none of the direction overrides or
/// invisible characters that could make it read differently than it is, and
/// at most [maxLength] characters.
String cleanServerText(String text,
    {required int maxLength, bool multiline = false}) {
  final out = StringBuffer();
  var length = 0;
  for (final rune in text.replaceAll('\r\n', '\n').runes) {
    if (length >= maxLength) {
      out.write('\u2026');
      break;
    }
    if (rune == 0x0A) {
      out.writeCharCode(multiline ? 0x0A : 0x20);
      length++;
      continue;
    }
    if (rune == 0x09) {
      out.writeCharCode(0x20);
      length++;
      continue;
    }
    if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) continue;
    if (_isInvisibleOrDirectional(rune)) continue;
    out.writeCharCode(rune);
    length++;
  }
  return out.toString().trim();
}

bool _isInvisibleOrDirectional(int rune) =>
    rune == 0x00AD || // soft hyphen
    rune == 0x061C || // Arabic letter mark
    (rune >= 0x200B && rune <= 0x200F) || // zero-width, LRM, RLM
    (rune >= 0x202A && rune <= 0x202E) || // embeddings and overrides
    (rune >= 0x2060 && rune <= 0x2069) || // word joiner, isolates
    rune == 0xFEFF; // zero-width no-break space

/// Answers a server's keyboard-interactive questions (RFC 4256), with one set
/// of rules for every ZestSSH connection:
///
/// * the saved password goes only to a real password prompt
///   ([isRealPasswordPrompt]), and only once per connection: a second
///   password prompt means the server did not take it, and repeating it would
///   only count towards a lockout;
/// * a password saved with a key ([passwordAfterKey]) is fetched the first
///   time a server asks for a password, and never where none does;
/// * every other question goes to the person through [ask], as the server's
///   own words with nothing filled in;
/// * with nobody to ask (a background connection) the rest is answered with
///   empty strings, so the sign-in fails closed;
/// * answers are never logged, and neither is the server's text.
///
/// One instance serves one connection attempt.
class KeyboardInteractiveAnswerer {
  KeyboardInteractiveAnswerer({
    String? password,
    Future<String?> Function()? passwordAfterKey,
    this.ask,
    Future<void>? withdrawn,
    this.onServerActive,
    this.onLog,
  })  : _password = password,
        _fetchPasswordAfterKey = passwordAfterKey,
        _withdrawn = withdrawn ?? Completer<void>().future;

  final String? _password;

  /// Fetches the password saved with a key (3.0, accounts per host), where
  /// there is one: called once at most, by [passwordAfterKey].
  final Future<String?> Function()? _fetchPasswordAfterKey;
  Future<String?>? _passwordAfterKey;

  /// Shows questions to the person; null on a background connection.
  final ServerQuestionAsker? ask;

  /// Called whenever the server sends a keyboard-interactive request, so the
  /// caller can give the sign-in more time ([kServerQuestionPatience]).
  final void Function()? onServerActive;

  final void Function(String line)? onLog;

  final Future<void> _withdrawn;
  bool _passwordSent = false;
  int _round = 0;
  bool _cancelled = false;

  /// True once the person cancelled a question in this sign-in.
  bool get cancelled => _cancelled;

  /// Whether offering keyboard-interactive can lead anywhere: with no saved
  /// password and nobody to ask, every answer would be empty.
  bool get canAnswer => _password != null || _fetchPasswordAfterKey != null || ask != null;

  /// The password saved with a key, for a server that did not take the key
  /// and asks for a password, as the way "password" or as a real password
  /// prompt: fetched the first time it is asked for, and the same answer
  /// after that. Null where there is none (or where it may not be sent,
  /// which the fetch says by itself).
  Future<String?> passwordAfterKey() => _passwordAfterKey ??= _fetchAfterKey();

  Future<String?> _fetchAfterKey() async {
    final fetch = _fetchPasswordAfterKey;
    if (fetch == null) return null;
    try {
      return await fetch();
    } catch (e) {
      _passwordAfterKeyStopped = e;
      rethrow;
    }
  }

  /// What stopped the sign-in while the password saved with a key was being
  /// fetched, where something did: an Orchard's rule, or the person
  /// cancelling where it was asked for. The sign-in is said as that, and not
  /// as the SSH library's error around it.
  Object? get passwordAfterKeyStopped => _passwordAfterKeyStopped;
  Object? _passwordAfterKeyStopped;

  /// What stopped the sign-in at a question that was being put to [ask],
  /// where something did: a run with nobody there to answer it (3.0). The
  /// sign-in is said as that, and not as the SSH library's error around it.
  Object? get questionStopped => _questionStopped;
  Object? _questionStopped;

  /// What stopped the sign-in by itself, where something did: the password
  /// saved with a key, or a question ([passwordAfterKeyStopped],
  /// [questionStopped]).
  Object? get stoppedBy => _passwordAfterKeyStopped ?? _questionStopped;

  /// The password saved with a key, once fetched for a real password prompt.
  String? _fetched;

  /// The handler for [SSHClient.onUserInfoRequest], or null when
  /// keyboard-interactive is not worth offering ([canAnswer]).
  SSHUserInfoRequestHandler? get handler => canAnswer
      ? (request) => answer(
            request.name,
            request.instruction,
            [
              for (final p in request.prompts)
                (text: p.promptText, echo: p.echo),
            ],
          )
      : null;

  /// Answers one request: automatic answers first, then the person for the
  /// rest. Throws [SshPromptCancelled] when they cancel.
  Future<List<String>> answer(
    String name,
    String instruction,
    List<({String text, bool echo})> prompts,
  ) async {
    // A password saved with a key is fetched only for a real password
    // prompt it would answer.
    if (_password == null &&
        _fetchPasswordAfterKey != null &&
        !_passwordSent &&
        prompts.any((p) => isRealPasswordPrompt(p.text, echo: p.echo))) {
      _fetched = await passwordAfterKey();
    }
    final asker = ask;
    if (asker == null) return answerUnattended(prompts);
    _round++;
    onServerActive?.call();
    if (prompts.isEmpty) return _messageOnly();

    final answers = _automaticAnswers(prompts);
    final open = [
      for (var i = 0; i < prompts.length; i++)
        if (answers[i] == null) i,
    ];
    if (open.isEmpty) {
      onLog?.call('ssh_auth: Sending credentials');
      return [for (final a in answers) a!];
    }

    onLog?.call('ssh_auth: The server asks ${open.length} question(s); '
        'waiting for your answer');
    final List<String>? replies;
    try {
      replies = await asker(ServerQuestion(
        name: cleanServerText(name, maxLength: kServerQuestionNameMax),
        instruction: cleanServerText(instruction,
            maxLength: kServerQuestionInstructionMax, multiline: true),
        prompts: [
          for (final i in open)
            ServerPrompt(
              cleanServerText(prompts[i].text, maxLength: kServerPromptMax),
              echo: prompts[i].echo,
            ),
        ],
        round: _round,
        withdrawn: _withdrawn,
      ));
    } catch (e) {
      _questionStopped = e;
      rethrow;
    }
    if (replies == null || replies.length != open.length) {
      _cancelled = true;
      onLog?.call('ssh_auth: Sign-in cancelled at the server\'s question');
      throw const SshPromptCancelled();
    }
    for (var j = 0; j < open.length; j++) {
      answers[open[j]] = replies[j];
    }
    onLog?.call('ssh_auth: Sending your answer');
    return [for (final a in answers) a!];
  }

  /// Answers for a connection nobody is watching: the saved password for a
  /// real password prompt (once), empty strings for everything else, so the
  /// sign-in fails closed instead of guessing.
  List<String> answerUnattended(List<({String text, bool echo})> prompts) {
    _round++;
    onServerActive?.call();
    if (prompts.isEmpty) return _messageOnly();
    final answers = _automaticAnswers(prompts);
    final unanswered = answers.where((a) => a == null).length;
    if (unanswered == 0) {
      onLog?.call('ssh_auth: Sending credentials');
    } else {
      onLog?.call('ssh_auth: The server asked $unanswered question(s) '
          'that need a person; answering empty (nobody to ask)');
      AppLogger.warning('SSH keyboard-interactive: $unanswered prompt(s) '
          'need a person on an unattended connection - sending empty '
          'responses');
    }
    return [for (final a in answers) a ?? ''];
  }

  List<String> _messageOnly() {
    // Only a message, for example that a push was sent to a phone.
    onLog?.call('ssh_auth: The server sent a message during sign-in');
    return const [];
  }

  /// Answers that need nobody: the saved password for a real password
  /// prompt, once per connection. Null where a person has to answer.
  List<String?> _automaticAnswers(List<({String text, bool echo})> prompts) {
    final password = _password ?? _fetched;
    return [
      for (final p in prompts)
        if (password != null &&
            !_passwordSent &&
            isRealPasswordPrompt(p.text, echo: p.echo))
          _sendPassword(password)
        else
          null,
    ];
  }

  String _sendPassword(String password) {
    _passwordSent = true;
    return password;
  }
}

/// The password saved with a key, for the way "password" of a server that
/// did not take the key ([KeyboardInteractiveAnswerer.passwordAfterKey]):
/// fetched now, and said in the connection's log where it is sent. The
/// answer of [SSHClient.onPasswordRequest] where a key has one (3.0,
/// accounts per host).
Future<String?> sendPasswordAfterKey(
  KeyboardInteractiveAnswerer answerer,
  void Function(String line)? onLog,
) async {
  final password = await answerer.passwordAfterKey();
  if (password != null) {
    onLog?.call('ssh_auth: The key was not taken; sending the password saved with it');
  }
  return password;
}

/// A sign-in that was given up because nothing came from the host for as
/// long as a server is given to answer ([AuthDeadline]), outside of what its
/// person was being asked: the host took the connection, and then said
/// nothing, or not enough. Every clock a session's sign-in is held to fails
/// with this, so that whatever shows the failure knows it by one text
/// (ConnectionError.translate). It was a time-out with a sentence of its
/// own at each place, and all of them were shown as a connection that the
/// server had closed.
class SignInTimedOut extends TimeoutException implements HasTypeName {
  SignInTimedOut(Duration waited) : super('Authentication timed out', waited);

  @override
  String get typeName => 'SignInTimedOut';
}

/// Waits for SSH authentication with a time limit that stops while the
/// person is answering the server's questions: 15 seconds is plenty for a
/// server to reply and far too little for a person to find a code.
///
/// Use [whileAsking] around each question, [relax] once the server has
/// started asking, then [wait] for the result.
class AuthDeadline {
  /// [limit] is how long a server is given to answer: 15 seconds where none
  /// is given.
  AuthDeadline([Duration? limit]) : _limit = limit ?? debugPatience ?? const Duration(seconds: 15);

  /// How long a server is given where no limit is given, for tests (which
  /// cannot wait the real 15 seconds): of a host's sign-in, of a console
  /// server's, of a jump host's and of a connection test's (its 8 seconds)
  /// alike. Null in the app.
  @visibleForTesting
  static Duration? debugPatience;

  /// A clock with [appLimit] in the app ([debugPatience] in a test), for a
  /// caller whose own limit is not the 15 seconds (the connection test's 8).
  factory AuthDeadline.within(Duration appLimit) => AuthDeadline(debugPatience ?? appLimit);

  Duration _limit;
  final _expired = Completer<void>();
  Timer? _timer;
  int _asking = 0;
  bool _waiting = false;
  bool _done = false;

  /// Runs [question] with the clock stopped; it restarts, in full, when the
  /// answer is in.
  Future<T> whileAsking<T>(Future<T> Function() question) async {
    _asking++;
    _timer?.cancel();
    _timer = null;
    try {
      return await question();
    } finally {
      _asking--;
      _restart();
    }
  }

  /// How long the server may be silent now: what it was given, or longer
  /// once [relax] gave it more.
  Duration get limit => _limit;

  /// Allows the server up to [limit] of silence from now on, if that is
  /// longer than what it has.
  void relax(Duration limit) {
    if (limit <= _limit) return;
    _limit = limit;
    _restart();
  }

  /// Completes like [authenticated], or fails once the server has been
  /// silent for the limit outside of questions: with [SignInTimedOut] and
  /// that limit, or with what [onTimeout] returns where whoever waits words
  /// it for themselves.
  Future<void> wait(Future<void> authenticated, {Exception Function()? onTimeout}) async {
    _waiting = true;
    _restart();
    try {
      await Future.any([
        authenticated,
        _expired.future.then<void>((_) => throw onTimeout?.call() ?? SignInTimedOut(_limit)),
      ]);
    } finally {
      _done = true;
      _timer?.cancel();
    }
  }

  void _restart() {
    if (!_waiting || _done || _asking > 0) return;
    _timer?.cancel();
    _timer = Timer(_limit, () {
      if (!_expired.isCompleted) _expired.complete();
    });
  }
}

/// [keys] for a sign-in that [deadline] is the clock of: the clock stops
/// while one of them signs, and starts again in full when it has. A key
/// that an SSH agent or a hardware key holds signs when its person has
/// touched it or typed its PIN, which takes a person's time and not a
/// server's: it ran against the server's fifteen seconds, and a touch that
/// came later than that was a sign-in that had timed out. (A key of this
/// device signs at once.)
List<SSHKeyPair> signingOffTheClock(List<SSHKeyPair>? keys, AuthDeadline deadline) =>
    [for (final key in keys ?? const <SSHKeyPair>[]) _OffTheClock(key, deadline)];

class _OffTheClock extends SSHKeyPair implements SSHRsaSignatureChoice {
  _OffTheClock(this._key, this._deadline);

  final SSHKeyPair _key;
  final AuthDeadline _deadline;

  /// Of the kinds of RSA signature it says what the key it stands for says,
  /// so that the SSH core picks the kind a host takes for that key.
  @override
  List<String> get rsaSignatureTypes => switch (_key) {
        SSHRsaSignatureChoice(:final rsaSignatureTypes) => rsaSignatureTypes,
        _ => const [],
      };

  @override
  SSHKeyPair signingAsRsa(String type) => _OffTheClock((_key as SSHRsaSignatureChoice).signingAsRsa(type), _deadline);

  @override
  String get name => _key.name;

  @override
  String get type => _key.type;

  @override
  core_hk.SSHHostKey toPublicKey() => _key.toPublicKey();

  @override
  SSHSignature sign(Uint8List data) => _key.sign(data);

  @override
  Future<SSHSignature> signAsync(Uint8List data) => _deadline.whileAsking(() => _key.signAsync(data));

  @override
  String toPem() => _key.toPem();
}

/// How long a sign-in waits once the server's login banner has given its
/// person a link to open: Tailscale SSH in "check" mode sends one ("To
/// authenticate, visit: https://login.tailscale.com/a/...") and answers the
/// sign-in only once the person has approved it there. The usual 15 seconds
/// ended the sign-in first (it worked on
/// a computer, and never on an iPhone).
const kSignInLinkPatience = Duration(minutes: 5);

/// Longest login banner shown in a [SignInNotice].
const kSignInNoticeMax = 2000;

/// A server's login banner (SSH_MSG_USERAUTH_BANNER) for its person, cleaned:
/// no escape sequences, no control characters, no invisible or direction
/// characters, at most [kSignInNoticeMax] characters; and the first https
/// link in it ([link]), which the app offers to open and never opens by
/// itself.
class SignInNotice {
  SignInNotice._(this.text, this.link, this.withdrawn);

  /// [banner] as the server sent it; [withdrawn] completes when the sign-in
  /// is over (done, failed or cancelled), and whatever shows the notice
  /// closes then.
  factory SignInNotice.of(String banner, {Future<void>? withdrawn}) {
    // A banner is the server's to size: only its start is looked at.
    final head = banner.length > 16384 ? banner.substring(0, 16384) : banner;
    final plain = _withoutEscapes(head);
    return SignInNotice._(
      cleanServerText(plain, maxLength: kSignInNoticeMax, multiline: true),
      _firstHttpsLink(cleanServerText(plain, maxLength: 8192, multiline: true)),
      withdrawn ?? Completer<void>().future,
    );
  }

  /// A notice [SignInNotice.of] made elsewhere (on a connection worker's
  /// isolate, where the banner arrives), from its [text] and [link] as they
  /// came over: cleaned again, and the link offered only where it is one
  /// that [SignInNotice.of] offers. Both hold for what [SignInNotice.of]
  /// made, so a notice comes over as it was.
  factory SignInNotice.carried(String text, String? link, {Future<void>? withdrawn}) {
    final offered = link == null ? null : _firstHttpsLink(cleanServerText(link, maxLength: 8192, multiline: false));
    return SignInNotice._(
      cleanServerText(text, maxLength: kSignInNoticeMax, multiline: true),
      offered != null && offered.toString() == link ? offered : null,
      withdrawn ?? Completer<void>().future,
    );
  }

  /// The banner's words, safe to show.
  final String text;

  /// The first https link in the banner, or null: only https, with a host,
  /// and with no user name before the host (which could make a link read
  /// as going somewhere it does not).
  final Uri? link;

  /// Completes when the sign-in is over.
  final Future<void> withdrawn;
}

/// Shows [notice] to the person, and completes with true where they cancel
/// the sign-in, false where it was withdrawn first.
typedef SignInNoticeShower = Future<bool> Function(SignInNotice notice);

/// What a sign-in does with its server's login banner where a person is
/// there to see it: one with an https link ([SignInNotice]: Tailscale SSH's
/// "check" mode) goes to them at once through the shower, and the server is
/// given [kSignInLinkPatience] to answer, the time it takes them to open the
/// link and approve. Every sign-in a person watches goes through this one
/// (a session's, each jump host's on its way, a console server's, a run's,
/// a connection test's), so that what they do cannot drift apart.
///
/// [banner] is the client's onUserauthBanner; [orCancelled] wraps what the
/// sign-in waits on; [cancelled] says whether the person cancelled at the
/// link. With no shower (a sign-in nobody watches) a banner changes
/// nothing: the sign-in gets no more time.
class SignInLinkBanners {
  SignInLinkBanners(
    this._show, {
    required AuthDeadline deadline,
    required Future<void> withdrawn,
    void Function(String line)? onLog,
  })  : _deadline = deadline,
        _withdrawn = withdrawn,
        _onLog = onLog;

  final SignInNoticeShower? _show;
  final AuthDeadline _deadline;

  /// Completes when the sign-in is over: the notice closes then.
  final Future<void> _withdrawn;
  final void Function(String line)? _onLog;
  final _cancelled = Completer<void>();

  /// Whether the person cancelled the sign-in at a banner's link.
  bool get cancelled => _cancelled.isCompleted;

  /// A notice was shown for this sign-in: the server chooses how many
  /// banners it sends, and only the first with a link is put to the person
  /// and stretches the clock (the 3.4 security review).
  bool _shown = false;

  /// Takes the server's login banner [message].
  void banner(String message) {
    final show = _show;
    if (show == null || _shown) return;
    final notice = SignInNotice.of(message, withdrawn: _withdrawn);
    final link = notice.link;
    if (link == null) return;
    _shown = true;
    _onLog?.call('ssh_auth: The banner has a link to ${link.host}; waiting for the sign-in to be finished there');
    _deadline.relax(kSignInLinkPatience);
    unawaited(show(notice).then((cancelled) {
      if (cancelled && !_cancelled.isCompleted) _cancelled.complete();
    }, onError: (Object _) {}));
  }

  /// [authenticated], or [SshPromptCancelled] as soon as the person cancels
  /// at a banner's link.
  Future<void> orCancelled(Future<void> authenticated) {
    if (_show == null) return authenticated;
    return Future.any([
      authenticated,
      _cancelled.future.then<void>((_) => throw const SshPromptCancelled()),
    ]);
  }
}

/// [text] without terminal escape sequences: CSI (colours, cursor moves),
/// OSC (titles, links), the string commands (DCS, SOS, PM, APC) and the
/// short ones. What a sequence leaves behind of itself would read as words.
String _withoutEscapes(String text) => text
    .replaceAll(RegExp('\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)?'), '')
    .replaceAll(RegExp('(?:\x1b\\[|\x9b)[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]?'), '')
    .replaceAll(RegExp('\x1b[PX^_][^\x1b]*(?:\x1b\\\\)?'), '')
    .replaceAll(RegExp('\x1b[\x20-\x2f]*[\x30-\x7e]?'), '');

final RegExp _kHttpsLink = RegExp('https://[^\\s<>"\'`…]+', caseSensitive: false);

final RegExp _ipLiteral = RegExp(r'^(\d{1,3}(\.\d{1,3}){3}|[0-9a-fA-F:.]*:[0-9a-fA-F:.]*)$');

Uri? _firstHttpsLink(String text) {
  for (final match in _kHttpsLink.allMatches(text)) {
    final found = match.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]}]+$'), '');
    if (found.length > 2048) continue;
    final uri = Uri.tryParse(found);
    if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      continue;
    }
    // (A bare address names no one a person could recognise: not offered.)
    if (_ipLiteral.hasMatch(uri.host)) continue;
    return uri;
  }
  return null;
}

