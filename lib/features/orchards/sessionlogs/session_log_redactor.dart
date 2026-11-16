/// What a team session log leaves out (3.0), before it is sealed
/// and sent. Known credentials and sensitive fields are redacted; terminal
/// output may still contain sensitive information this does not recognize.
///
/// It recognizes:
///   * values this device knows are secret in the session: the value of
///     every masked snippet variable (`${VAR:secret}`, `${VAR:password}`)
///     typed into it, wherever they appear (four characters or longer). The
///     password or passphrase the session signed in with is not kept for
///     this: the app wipes it from memory once signed in, and servers do not
///     show it;
///   * private key blocks (`-----BEGIN ... PRIVATE KEY-----` to the matching
///     END line), whole;
///   * passwords inside URLs (`scheme://user:password@host`);
///   * `Authorization: Bearer ...` and `Authorization: Basic ...` values;
///   * well-known token formats: GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`,
///     `ghr_`, `github_pat_`), GitLab (`glpat-`), AWS access key ids
///     (`AKIA`, `ASIA`), Slack (`xoxa-`, `xoxb-`, `xoxp-`, `xoxr-`,
///     `xoxs-`), Stripe secret and restricted keys (`sk_live_`, `sk_test_`,
///     `rk_live_`, `rk_test_`), Google API keys (`AIza`), OpenAI and
///     Anthropic keys (`sk-...`, `sk-ant-...`), npm tokens (`npm_`), and JSON
///     Web Tokens (`eyJ...` in three parts);
///   * values after a name ending in `password`, `passwd`, `pwd`, `secret`,
///     `token`, `api_key`, `apikey`, `access_key`, `secret_key` or
///     `private_key` (so `DB_PASSWORD` and `GITHUB_TOKEN` too) followed by
///     `=` or `:` on the same line.
///
/// Every pattern runs in time linear in the text: a pattern that could scan
/// ahead from every position of a long run (`a-a-a-...`) starts only where
/// such a run starts, and what it scans for is bounded, so output crafted to
/// make it slow cannot hold the app up.
///
/// Pure Dart, no Flutter or app imports, so it is testable on its own.
library;

/// What replaces what is left out.
const String kRedacted = '[redacted]';

/// What replaces a private key block.
const String kRedactedPrivateKey = '[redacted private key]';

/// Secrets shorter than this are not looked for: they would hide ordinary
/// text.
const int kMinSecretLength = 4;

// A private key block runs from a BEGIN line to the first END line after
// it; the two are found separately and paired in one pass (a single pattern
// across the block would scan to the end of the text from every BEGIN that
// has no END).
final RegExp _privateKeyBegin = RegExp(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----');
final RegExp _privateKeyEnd = RegExp(r'-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----');

/// Each pattern keeps its group 1 (a label or prefix) and redacts the rest of
/// the match.
final List<RegExp> _labelled = [
  // scheme://user:password@host
  RegExp(r'(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]{0,31}://[^\s/:@]{1,128}:)[^\s/@]{1,256}(?=@)'),
  // Authorization headers.
  RegExp(r'(\bAuthorization:\s*(?:Bearer|Basic|Token)\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
  // key = value / key: value for names that hold secrets.
  RegExp(
    r'''(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{0,64}?(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key)\b["']?\s*[:=]\s*["']?)[^\s"',;]{3,}''',
    caseSensitive: false,
  ),
];

/// Whole-match patterns: well-known token formats.
final List<RegExp> _tokens = [
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
  RegExp(r'\bgithub_pat_[A-Za-z0-9_]{40,}\b'),
  RegExp(r'\bglpat-[A-Za-z0-9_-]{20,}\b'),
  RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'),
  RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'),
  RegExp(r'\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b'),
  RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
  RegExp(r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}\b'),
  RegExp(r'\bnpm_[A-Za-z0-9]{30,}\b'),
  RegExp(r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'),
];

class SessionLogRedactor {
  final _secrets = <String>{};

  /// The values this redactor looks for, longest first (so a secret that
  /// contains another is left out whole).
  List<String> get secrets => _secrets.toList()..sort((a, b) => b.length.compareTo(a.length));

  /// Leaves [value] out of the log wherever it appears: a password,
  /// passphrase or masked snippet value used in this session. Values shorter
  /// than [kMinSecretLength] are ignored.
  void addSecret(String value) {
    if (value.length >= kMinSecretLength) _secrets.add(value);
  }

  /// [text] with everything this redactor recognizes replaced.
  String redact(String text) {
    var out = _withoutPrivateKeys(text);
    for (final s in secrets) {
      out = out.replaceAll(s, kRedacted);
    }
    for (final re in _labelled) {
      out = out.replaceAllMapped(re, (m) => '${m.group(1)}$kRedacted');
    }
    for (final re in _tokens) {
      out = out.replaceAll(re, kRedacted);
    }
    return out;
  }

  /// Where a private key block starts in [text] without ending there: text
  /// from here on waits until its END line arrives. Null when none is open.
  static int? openPrivateKeyAt(String text) {
    final last = _privateKeyBegin.allMatches(text).lastOrNull;
    if (last == null) return null;
    final end = _privateKeyEnd.allMatches(text).lastOrNull;
    return end != null && end.start >= last.end ? null : last.start;
  }

  /// [text] with every whole private key block replaced by
  /// [kRedactedPrivateKey]: each BEGIN line with the first END line after
  /// it. A BEGIN with no END after it stays (the writer holds it back).
  static String _withoutPrivateKeys(String text) {
    final ends = _privateKeyEnd.allMatches(text).toList();
    if (ends.isEmpty) return text;
    final out = StringBuffer();
    var from = 0;
    var e = 0;
    for (final begin in _privateKeyBegin.allMatches(text)) {
      // Inside a block already left out.
      if (begin.start < from) continue;
      while (e < ends.length && ends[e].start < begin.end) {
        e++;
      }
      if (e == ends.length) break;
      out
        ..write(text.substring(from, begin.start))
        ..write(kRedactedPrivateKey);
      from = ends[e].end;
      e++;
    }
    out.write(text.substring(from));
    return out.toString();
  }
}
