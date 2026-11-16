import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// What a failure the app itself put into words starts with, where it is
/// kept as text (a session's error, a report): a sign-in the app could not
/// start (a certificate that waits for an owner, a password manager that
/// gave nothing, a key that is not there), a host it was told to skip.
/// Everything that shows a failure reads it through
/// [ConnectionError.translate], which shows what follows the mark as it is.
/// Text without it is a library's or the system's, in whatever words they
/// use, and is matched against what is known of those.
///
/// It is words and not a hidden sign on purpose: the text also goes into
/// reports and logs, where it should say who is speaking.
const String kSaidByApp = 'ZestSSH: ';

/// [message], which the app itself wrote for the person, marked as that.
String saidByApp(String message) => '$kSaidByApp$message';

/// [raw], the text of a sign-in that the server refused, with what was tried
/// and what the server takes at its end: a failed connection is kept as
/// text, and whatever shows it says from this which it was
/// ([ConnectionError.translate]), and whoever reads its details sees it.
///
/// What a server calls its ways is its own text. Only what a name of the
/// protocol can be is kept of it ([_wayNames]), so nothing of a server's
/// making reaches a screen or a log by this. ([tried] is the client's own.)
String withSignInWays(String raw, List<String> tried, List<String> takes) =>
    '$raw [tried: ${tried.join(',')}] [the server takes: ${_wayNames(takes).join(',')}]';

/// What a sign-in tried and what its server takes, where [raw] ends with it
/// ([withSignInWays]). Null for a text that does not.
({List<String> tried, List<String> takes})? signInWaysOf(String raw) {
  final kept = _waysKept.firstMatch(raw);
  if (kept == null) return null;
  List<String> names(String list) => list.isEmpty ? const [] : list.split(',');
  return (tried: names(kept[1]!), takes: names(kept[2]!));
}

/// The names among [names] that a way of signing in can have (letters,
/// digits and a few signs, as "publickey" and "gssapi-with-mic" have; none
/// longer than a name is), at most ten of them, or [most].
List<String> _wayNames(List<String> names, [int most = 10]) => names.where(_wayName.hasMatch).take(most).toList();

final _wayName = RegExp(r'^[A-Za-z0-9@._+-]{1,64}$');
final _waysKept = RegExp(r' \[tried: ([A-Za-z0-9@._+,-]*)\] \[the server takes: ([A-Za-z0-9@._+,-]*)\]$');

/// [raw], the text of a sign-in that the server refused, with the keys that
/// were not offered to the server at all, by their kinds, and the kinds of
/// signature the server said it takes: the SSH core passes an RSA key over
/// where a server has said that it takes none of the signatures the key
/// may make here. [raw] as it is where no key was passed over. What was
/// tried goes after it ([withSignInWays]).
///
/// Only names are kept of both lists, as of a server's ways of signing in.
String withKeysPassedOver(String raw, List<String> kinds, List<String>? signatures) => kinds.isEmpty
    ? raw
    : '$raw [keys passed over: ${_wayNames(kinds).join(',')}] '
        '[signatures the server takes: ${_wayNames(signatures ?? const [], 40).join(',')}]';

/// The kinds of signature the server takes, where [raw] says that keys
/// were passed over for them ([withKeysPassedOver]). Null for a text that
/// does not.
List<String>? signaturesKeysWerePassedOverFor(String raw) {
  final kept = _passedOverKept.firstMatch(raw);
  if (kept == null) return null;
  return kept[1]!.isEmpty ? const [] : kept[1]!.split(',');
}

final _passedOverKept =
    RegExp(r' \[keys passed over: [A-Za-z0-9@._+,-]*\] \[signatures the server takes: ([A-Za-z0-9@._+,-]*)\]');
final _passedOverAtEnd = RegExp('${_passedOverKept.pattern}\$');

/// [raw], the text of a key exchange that ended with no algorithm of one
/// kind in common, with what each side offered of that kind at its end
/// ([offered], [serverOffers]), and what Compatibility mode has of it that
/// was not offered and that the server offers ([modeAdds]: nothing where
/// the connection was made with the mode, or where the server offers
/// nothing the mode has). A failed connection is kept as text, and
/// whatever shows it says from this what there is to do
/// ([ConnectionError.translate]); whoever reads its details sees what each
/// side has.
///
/// What a server calls its algorithms is its own text. Only what a name of
/// the protocol can be is kept of it, as of its ways of signing in, and at
/// most [mostAlgorithmsKept] of them, with "..." after them where there
/// were more ([_algorithmNames]).
String withAlgorithmsOffered(
  String raw, {
  required List<String> offered,
  required List<String> serverOffers,
  required List<String> modeAdds,
}) =>
    '$raw [ZestSSH offered: ${_algorithmNames(offered).join(',')}] '
    '[the server offers: ${_algorithmNames(serverOffers).join(',')}] '
    '[Compatibility mode adds: ${_algorithmNames(modeAdds).join(',')}]';

/// What each side of a key exchange offered and what Compatibility mode
/// adds, where [raw] ends with it ([withAlgorithmsOffered]). Null for a
/// text that does not.
({List<String> offered, List<String> serverOffers, List<String> modeAdds})? algorithmsOfferedOf(String raw) {
  final kept = _offeredKept.firstMatch(raw);
  if (kept == null) return null;
  List<String> names(String list) => list.isEmpty ? const [] : list.split(',');
  return (offered: names(kept[1]!), serverOffers: names(kept[2]!), modeAdds: names(kept[3]!));
}

/// How many names of algorithms are kept of what one side offered.
const mostAlgorithmsKept = 40;

/// The names among [names] that an algorithm can have, at most
/// [mostAlgorithmsKept] of them; where there were more, "..." stands after
/// them, so that what is said of the list does not say that it is whole.
List<String> _algorithmNames(List<String> names) {
  final kept = names.where(_wayName.hasMatch).toList();
  return kept.length <= mostAlgorithmsKept ? kept : [...kept.take(mostAlgorithmsKept), '...'];
}

final _offeredKept = RegExp(r' \[ZestSSH offered: ([A-Za-z0-9@._+,-]*)\] \[the server offers: ([A-Za-z0-9@._+,-]*)\] '
    r'\[Compatibility mode adds: ([A-Za-z0-9@._+,-]*)\]$');

/// What [raw], a failed connection as it is kept, says by itself: without
/// what was put at its end for whoever shows it ([withAlgorithmsOffered];
/// [withSignInWays], and [withKeysPassedOver] before that). What is
/// matched against the words of known failures is this, so that no name of
/// a server's making is taken for the words of an error: a server that
/// called one of its ways of signing in "sshkeydecrypterror" had its
/// refusal shown as a key that needs its passphrase.
String saidByItself(String raw) {
  final offered = _offeredKept.firstMatch(raw);
  if (offered != null) return raw.substring(0, offered.start);
  final ways = _waysKept.firstMatch(raw);
  if (ways == null) return raw;
  final before = raw.substring(0, ways.start);
  return before.substring(0, _passedOverAtEnd.firstMatch(before)?.start ?? before.length);
}

/// What is said of an RSA key that was not offered to a server, since the
/// server had said that it takes no kind of signature the key may make
/// here, by the kinds the server takes ([signatures]): that it takes the
/// first kind only (with SHA-1), which the app makes in Compatibility mode,
/// with where that switch is ([compatibilityModePlace]), or that it takes
/// no RSA key at all. Each says what to do about it.
String rsaKeyPassedOverText(AppLocalizations l10n, List<String> signatures, {bool? onAComputer}) =>
    signatures.contains('ssh-rsa')
        ? l10n.errSignInRsaOnlySha1(compatibilityModePlace(l10n, onAComputer: onAComputer))
        : l10n.errSignInRsaNotTaken;

/// Where the editor of a connection has its Compatibility mode switch, by
/// the names the editor shows for the place. The editor has two forms. With
/// tabs, as it is docked or opened as a dialog on a computer, the switch is
/// under the tab for the sign-in. Without tabs, as it is on a phone, and on
/// a computer where it is opened as a page of its own (from Server
/// Monitor's table, the command palette, a link), the switch is behind
/// "Show advanced options", and on a phone, whose form folds it (4.0), in
/// the fold "Advanced options". So a phone is told its fold, and a computer
/// both of its places. [onAComputer] is what this device is, unless a test
/// says otherwise.
///
/// (The place was said as "Advanced", which on a computer is a tab that
/// does not hold the switch; and a phone was told "Show advanced options"
/// after its form had come to say "Advanced options".)
String compatibilityModePlace(AppLocalizations l10n, {bool? onAComputer}) => (onAComputer ?? isDesktopPlatform)
    ? '${l10n.connectionEditRailAuth} / ${l10n.connectionEditShowAdvanced}'
    : l10n.hostFormAdvancedOptions;

/// The kind of algorithm that [raw], an error of the SSH core, says the app
/// and a host have none in common of ("No matching cipher algorithm"), in
/// the app's words. Null for an error that says nothing of the kind.
String? algorithmKindNotInCommon(AppLocalizations l10n, String raw) {
  // (Not what stands at its end of what each side offered: "hmac-sha2-256" is no word of the error.)
  final lower = saidByItself(raw).toLowerCase();
  if (!lower.contains('no matching') || !lower.contains('algorithm')) return null;
  if (lower.contains('mac')) return l10n.errAlgoTypeMac;
  if (lower.contains('cipher')) return l10n.errAlgoTypeCipher;
  if (lower.contains('host key')) return l10n.errAlgoTypeHostKey;
  if (lower.contains('key exchange')) return l10n.errAlgoTypeKeyExchange;
  return l10n.errAlgoTypeEncryption;
}

/// [names] as a list in a sentence: the app's words for the ways it has
/// words for, and the protocol's name for any other.
String _waysSaid(List<String> names) => names
    .map((name) => switch (name) {
          'publickey' => gl10n.errSignInWayKey,
          'password' => gl10n.errSignInWayPassword,
          'keyboard-interactive' => gl10n.errSignInWayQuestions,
          _ => name,
        })
    .join(gl10n.listSeparator);

/// Translates raw SSH/network exception strings into user-friendly messages.
///
/// Used by the connection error screen to replace cryptic error messages
/// like `SSHAuthAbortError(Connection closed before authentication)` with
/// human-readable descriptions and contextual tips.
class ConnectionError {
  final String title;
  final String description;
  final String? tip;
  final String rawError;
  final ConnectionErrorType type;

  const ConnectionError({
    required this.title,
    required this.description,
    this.tip,
    required this.rawError,
    required this.type,
  });

  /// Translate a raw error string into a structured [ConnectionError].
  ///
  /// [onAComputer] is what this device is, unless a test says otherwise
  /// ([compatibilityModePlace]).
  factory ConnectionError.translate(
    String raw, {
    String? host,
    int? port,
    String? username,
    bool? onAComputer,
  }) {
    // ── What the app itself said ────────────────────────────────────
    // Its own words, in the person's language, saying what is wrong and
    // what to do: shown as they are. (Matched against the words below they
    // matched nothing, in any language, and were shown as "an unexpected
    // error", with the reason only under the details.)
    if (raw.startsWith(kSaidByApp)) {
      return ConnectionError(
        type: ConnectionErrorType.saidByApp,
        title: gl10n.errConnectionFailedTitle,
        description: raw.substring(kSaidByApp.length),
        rawError: raw,
      );
    }
    // What the error says by itself: no name that a server gave something
    // is matched against the words of the failures below ([saidByItself]).
    final lower = saidByItself(raw).toLowerCase();

    // ── Key decryption failures ────────────────────────────────────
    if (lower.contains('sshkeydecrypterror') ||
        lower.contains('private key is encrypted') ||
        lower.contains('bad decrypt') && lower.contains('key')) {
      return ConnectionError(
        type: ConnectionErrorType.authKeyRejected,
        title: gl10n.errKeyPassphraseRequiredTitle,
        description: gl10n.errKeyPassphraseRequiredDesc,
        tip: gl10n.errKeyPassphraseRequiredTip,
        rawError: raw,
      );
    }

    // ── A sign-in that was not finished in time ─────────────────────
    // The app's own clock for it (SignInTimedOut): the host took the
    // connection and then went quiet for longer than a server is given to
    // answer. Nothing was refused, and nothing was closed.
    if (lower.contains('authentication timed out')) {
      return ConnectionError(
        type: ConnectionErrorType.signInTimedOut,
        title: gl10n.errSignInTimedOutTitle,
        description: gl10n.errSignInTimedOutDesc(host ?? gl10n.errFallbackServerCapitalized),
        tip: gl10n.errSignInTimedOutTip,
        rawError: raw,
      );
    }

    // ── Authentication failures ─────────────────────────────────────
    if (lower.contains('sshauthaborterror') ||
        lower.contains('authentication') ||
        lower.contains('auth') && lower.contains('fail') ||
        lower.contains('permission denied') ||
        lower.contains('access denied')) {
      // The server answered every way of signing in that was tried with a
      // refusal, and closed nothing (the library's SSHAuthFailError).
      if (lower.contains('sshauthfailerror')) return _refusedSignIn(raw, host: host, username: username);
      // Distinguish key vs password auth
      if (lower.contains('key') || lower.contains('publickey')) {
        return ConnectionError(
          type: ConnectionErrorType.authKeyRejected,
          title: gl10n.errKeyAuthFailedTitle,
          description: gl10n.errKeyAuthFailedDesc +
              (username != null ? ' ($username@${host ?? "server"})' : ''),
          tip: gl10n.errKeyAuthFailedTip,
          rawError: raw,
        );
      }
      if (lower.contains('password')) {
        return ConnectionError(
          type: ConnectionErrorType.authPasswordFailed,
          title: gl10n.errIncorrectPasswordTitle,
          description:
              gl10n.errIncorrectPasswordDesc(host ?? gl10n.errFallbackServerLower),
          tip: gl10n.errIncorrectPasswordTip,
          rawError: raw,
        );
      }
      // What is left is a connection that ended before the sign-in was over.
      return ConnectionError(
        type: ConnectionErrorType.authFailed,
        title: gl10n.errAuthFailedTitle,
        description: gl10n.errAuthFailedDesc + (host == null ? '' : ' ($host)'),
        tip: gl10n.errAuthFailedTip,
        rawError: raw,
      );
    }

    // ── Connection refused ──────────────────────────────────────────
    if (lower.contains('connection refused') ||
        lower.contains('refused')) {
      return ConnectionError(
        type: ConnectionErrorType.refused,
        title: gl10n.errRefusedTitle,
        description: gl10n.errRefusedDesc(
          host ?? gl10n.errFallbackServerCapitalized,
          port ?? 22,
        ),
        tip: gl10n.errRefusedTip,
        rawError: raw,
      );
    }

    // ── Timeout ─────────────────────────────────────────────────────
    // (And a host that stopped answering while a connection to it was being
    // made: the SSH library's SSHNoAnswerError.)
    if (lower.contains('timeout') || lower.contains('timed out') || lower.contains('sshnoanswererror')) {
      return ConnectionError(
        type: ConnectionErrorType.timeout,
        title: gl10n.errTimeoutTitle,
        description: gl10n.errTimeoutDesc(host ?? gl10n.errFallbackServerLower),
        tip: gl10n.errTimeoutTip,
        rawError: raw,
      );
    }

    // ── DNS / host not found ────────────────────────────────────────
    if (lower.contains('host not found') ||
        lower.contains('no address') ||
        lower.contains('name or service not known') ||
        lower.contains('nodename nor servname') ||
        lower.contains('getaddrinfo') ||
        lower.contains('failed host lookup')) {
      return ConnectionError(
        type: ConnectionErrorType.hostUnreachable,
        title: gl10n.errHostNotFoundTitle,
        description:
            gl10n.errHostNotFoundDesc(host ?? gl10n.errFallbackHostname),
        tip: gl10n.errHostNotFoundTip,
        rawError: raw,
      );
    }

    // ── Network / socket errors ─────────────────────────────────────
    if (lower.contains('socketexception') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('connection reset') ||
        lower.contains('broken pipe')) {
      return ConnectionError(
        type: ConnectionErrorType.networkError,
        title: gl10n.errNetworkErrorTitle,
        description:
            gl10n.errNetworkErrorDesc(host ?? gl10n.errFallbackServerLower),
        tip: gl10n.errNetworkErrorTip,
        rawError: raw,
      );
    }

    // ── Algorithm negotiation failures ──────────────────────────────
    // (Asked before a host key that changed: "No matching host key
    // algorithm" holds the words of both, and is this.)
    final algoType = algorithmKindNotInCommon(gl10n, raw);
    if (algoType != null) {
      // What each side offered, where the text has it. Then it is known
      // whether Compatibility mode has anything for this server: where it
      // has not (the connection was made with it, or the server offers
      // nothing of what it adds), the tip to turn it on would send its
      // reader to a switch that changes nothing, and what the server
      // offers is said in its place. (The tip was given whatever the
      // connection was made with and whatever the server offered.)
      final offers = algorithmsOfferedOf(raw);
      final modeCannotHelp = offers != null && offers.modeAdds.isEmpty;
      final server = host ?? gl10n.errFallbackServerLower;
      return ConnectionError(
        type: ConnectionErrorType.algorithmMismatch,
        title: gl10n.errAlgorithmMismatchTitle,
        description: modeCannotHelp && offers.serverOffers.isNotEmpty
            ? gl10n.errAlgorithmNoneInCommonDesc(algoType, server, offers.serverOffers.join(gl10n.listSeparator))
            : gl10n.errAlgorithmMismatchDesc(algoType, server),
        tip: modeCannotHelp
            ? gl10n.errAlgorithmNoneInCommonTip
            : gl10n.errAlgorithmMismatchTip(compatibilityModePlace(gl10n, onAComputer: onAComputer)),
        rawError: raw,
      );
    }

    // ── Host key mismatch ───────────────────────────────────────────
    if (lower.contains('host key') ||
        lower.contains('hostkey') ||
        lower.contains('server identity')) {
      return ConnectionError(
        type: ConnectionErrorType.hostKeyMismatch,
        title: gl10n.errHostKeyMismatchTitle,
        description: gl10n.errHostKeyMismatchDesc,
        tip: gl10n.errHostKeyMismatchTip,
        rawError: raw,
      );
    }

    // ── SSH protocol errors ─────────────────────────────────────────
    if (lower.contains('sshhandshakeerror') ||
        lower.contains('sshpacketerror') ||
        lower.contains('sshstateerror') ||
        lower.contains('sshsocketerror') ||
        lower.contains('sshinternalerror') ||
        lower.contains('handshake') ||
        lower.contains('kex') ||
        lower.contains('protocol mismatch')) {
      return ConnectionError(
        type: ConnectionErrorType.sshProtocol,
        title: gl10n.errSshProtocolTitle,
        description:
            gl10n.errSshProtocolDesc(host ?? gl10n.errFallbackServerLower),
        tip: gl10n.errSshProtocolTip,
        rawError: raw,
      );
    }

    // ── Fallback ────────────────────────────────────────────────────
    return ConnectionError(
      type: ConnectionErrorType.unknown,
      title: gl10n.errConnectionFailedTitle,
      description: gl10n.errUnknownDesc(host ?? gl10n.errFallbackServerLower),
      tip: gl10n.errUnknownTip,
      rawError: raw,
    );
  }

  /// A sign-in that the server refused, by what was tried and what the
  /// server takes, where [raw] says ([signInWaysOf]): the key alone, the
  /// password, or nothing that was offered, with who was signing in; what
  /// else the server takes; and, where it takes nothing this sign-in had,
  /// that, and that nothing was sent to it. (It was one sentence for all of
  /// them: the sentences for a key and for a password that the server
  /// rejected were there, and nothing said which of the two had been tried.)
  static ConnectionError _refusedSignIn(String raw, {String? host, String? username}) {
    final ways = signInWaysOf(raw);
    final tried = ways?.tried ?? const <String>[];
    final where = host == null ? '' : ' (${username == null ? '' : '$username@'}$host)';
    // An RSA key that was not offered at all, since the server had said that
    // it takes no signature the key may make here: said by itself where
    // nothing else was tried, and after whatever was tried and refused.
    // (Such a key was offered with a signature the server had said it
    // refuses, and what was shown was a key the server rejected, with a tip
    // to look at authorized_keys.)
    final signatures = signaturesKeysWerePassedOverFor(raw);
    final aboutRsa = signatures == null ? null : rsaKeyPassedOverText(gl10n, signatures);
    if (aboutRsa != null && tried.isEmpty) {
      return ConnectionError(
        type: ConnectionErrorType.authKeyRejected,
        title: gl10n.errKeyAuthFailedTitle,
        description: aboutRsa + where,
        rawError: raw,
      );
    }
    if (ways != null && tried.isEmpty) {
      return ConnectionError(
        type: ConnectionErrorType.authFailed,
        title: gl10n.errAuthFailedTitle,
        description:
            (ways.takes.isEmpty ? gl10n.errSignInTakesNothing : gl10n.errSignInTakesOnly(_waysSaid(ways.takes))) + where,
        tip: gl10n.errAuthFailedTip,
        rawError: raw,
      );
    }
    final untried = [
      for (final way in ways?.takes ?? const <String>[])
        if (!tried.contains(way)) way,
    ];
    String withWhatElse(String sentence) {
      final also = untried.isEmpty ? sentence : '$sentence ${gl10n.errSignInAlsoTakes(_waysSaid(untried))}';
      return aboutRsa == null ? also : '$also $aboutRsa';
    }
    if (tried.length == 1 && tried.single == 'publickey') {
      return ConnectionError(
        type: ConnectionErrorType.authKeyRejected,
        title: gl10n.errKeyAuthFailedTitle,
        description: withWhatElse(gl10n.errKeyAuthFailedDesc + where),
        tip: gl10n.errKeyAuthFailedTip,
        rawError: raw,
      );
    }
    // (Its questions alone may have been for a code, and are not said as a
    // password; with a key as well, it is not known which of them it was.)
    if (tried.contains('password') && !tried.contains('publickey')) {
      return ConnectionError(
        type: ConnectionErrorType.authPasswordFailed,
        title: gl10n.errIncorrectPasswordTitle,
        description: withWhatElse(gl10n.errIncorrectPasswordDesc(host ?? gl10n.errFallbackServerLower)),
        tip: gl10n.errIncorrectPasswordTip,
        rawError: raw,
      );
    }
    return ConnectionError(
      type: ConnectionErrorType.authFailed,
      title: gl10n.errAuthFailedTitle,
      description: withWhatElse(gl10n.errSignInRefusedDesc + where),
      tip: gl10n.errAuthFailedTip,
      rawError: raw,
    );
  }
}

/// Categories of connection errors.
enum ConnectionErrorType {
  /// The app's own words for it ([kSaidByApp]).
  saidByApp,
  authFailed,

  /// The host took the connection and did not finish the sign-in in the
  /// time a server is given for it.
  signInTimedOut,
  authPasswordFailed,
  authKeyRejected,
  timeout,
  refused,
  hostUnreachable,
  networkError,
  hostKeyMismatch,
  algorithmMismatch,
  sshProtocol,
  unknown,
}

/// A short, plain-language description of a failure, plus the raw technical
/// string kept aside for a "Copy details" affordance.
///
/// This is the counterpart to [ConnectionError] for the NON-SSH surfaces -
/// Cloud Sync, backend connection tests, Wake-on-LAN, update checks, and any
/// other HTTP/network path. Those used to dump the raw exception straight into
/// a SnackBar or a red card, producing walls of
/// `ClientException with SocketException: Failed host lookup 'api…' ...` that
/// mean nothing to a normal user. [message] is the one thing worth showing;
/// [detail] is the raw text, surfaced only behind a copy button for anyone
/// filing a bug.
class FriendlyError {
  /// One or two plain sentences a non-technical user can act on. Never
  /// contains a stack trace, class name, or raw socket text.
  final String message;

  /// The raw exception text, for a "Copy details" button. Null when [message]
  /// already conveys everything and there's nothing useful to copy.
  final String? detail;

  const FriendlyError(this.message, {this.detail});
}

/// [text] with its first letter a capital: "{where} refused the connection"
/// begins with what was reached ("the server"). A script without capitals
/// is left as it is.
String _sentence(String text) {
  if (text.isEmpty) return text;
  final first = text.substring(0, 1);
  final upper = first.toUpperCase();
  return upper == first ? text : '$upper${text.substring(1)}';
}

/// Translate a raw network/HTTP exception into a [FriendlyError].
///
/// [subject] names what we were trying to reach, in the app's language
/// ("Can't reach the sync server …"); it defaults to "the server". It is a
/// name for a kind of thing, never the name of a host: a sentence may begin
/// with it, and then its first letter is made a capital. The raw text is
/// always preserved in [FriendlyError.detail] so nothing is lost - it just
/// stops being the headline.
FriendlyError describeNetworkError(Object error, {String? subject}) {
  // Redact any `scheme://user:pass@host` credentials before the raw text is
  // kept for the copy-details / log path - a custom sync-server URL can embed
  // a password, and this string may reach the clipboard or the app log.
  // (With replaceAll, `$1` was written as it stands: "https$1***@host".)
  final raw = error.toString().replaceAllMapped(
        RegExp(r'(://)[^/@\s]+@'),
        (m) => '${m[1]}***@',
      );
  final lower = raw.toLowerCase();
  final where = (subject == null || subject.trim().isEmpty)
      ? gl10n.errFallbackServerLower
      : subject.trim();

  // ── Plain http where it is not allowed ────────────────────────────
  // The app's own rule (an address that is not on the person's own network),
  // or the platform's blanket refusal on a phone for a request that did not
  // go through that rule.
  if (error is PlainHttpRefused ||
      lower.contains('non-https connection')) {
    return FriendlyError(gl10n.plainHttpOwnNetworkOnly, detail: raw);
  }

  // ── DNS / host not found ──────────────────────────────────────────
  if (lower.contains('failed host lookup') ||
      lower.contains('getaddrinfo') ||
      lower.contains('nodename nor servname') ||
      lower.contains('name or service not known') ||
      lower.contains('no address associated')) {
    return FriendlyError(
      _sentence(gl10n.errNetDnsFailed(where)),
      detail: raw,
    );
  }

  // ── Connection refused ────────────────────────────────────────────
  if (lower.contains('connection refused') || lower.contains('refused')) {
    return FriendlyError(
      _sentence(gl10n.errNetRefused(where)),
      detail: raw,
    );
  }

  // ── Timeout ───────────────────────────────────────────────────────
  if (lower.contains('timed out') ||
      lower.contains('timeout') ||
      lower.contains('timeoutexception')) {
    return FriendlyError(
      _sentence(gl10n.errNetTimeout(where)),
      detail: raw,
    );
  }

  // ── TLS / certificate ─────────────────────────────────────────────
  if (lower.contains('handshakeexception') ||
      lower.contains('certificate') ||
      lower.contains('tlsexception') ||
      lower.contains('ssl') ||
      lower.contains('pin')) {
    return FriendlyError(
      _sentence(gl10n.errNetTls(where)),
      detail: raw,
    );
  }

  // ── Generic network / socket unreachable ──────────────────────────
  if (lower.contains('network is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('broken pipe') ||
      lower.contains('socketexception') ||
      lower.contains('clientexception') ||
      lower.contains('httpexception')) {
    return FriendlyError(
      _sentence(gl10n.errNetUnreachable(where)),
      detail: raw,
    );
  }

  // ── Fallback - still hide the raw text behind the copy button ──────
  return FriendlyError(
    _sentence(gl10n.errNetFallback(where)),
    detail: raw,
  );
}
