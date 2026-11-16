import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/utils/redactor.dart';

/// Text made fit to leave the app in an error report.
///
/// An error screen offers its details to copy, so that a person can paste
/// them to support, to Astryx or to any other assistant. Where they paste
/// it is theirs to choose, so what is copied must hold no secret, and must
/// not say which hosts, people or folders they have. [scrub] takes out, in
/// this order:
///
///  * private keys, public keys and their fingerprints;
///  * what a header, a field or a query calls a password, a passphrase, a
///    secret, a token or a key, and anything that looks like a token;
///  * web addresses: one of ZestSSH's own keeps its path and loses its
///    query; one of a service everybody uses keeps its host; any other is
///    masked whole;
///  * folders: the ones the app was told about ([registerFolder]) are called
///    by what they are (`<app data>`), an account's folder on the computer
///    is `<user>`, and of the rest only the names every computer has stay;
///  * long runs of letters and digits that read as data, tokens known by
///    how they begin (Slack, Stripe, GitHub, AWS), PEM blocks, a secret
///    after its name with only a blank between, and a one-time code after
///    "code" or "otp";
///  * the hosts the app keeps (`<host>`) and the usernames it signs in with
///    (`<user>`), quoted or not ([registerHosts], [registerUsernames]);
///  * then what recording mode masks in free text ([Redactor.line]):
///    `user@host`, addresses, and every name the app knows a host, a group,
///    a workspace, a network or a key by;
///  * and last a domain written by itself (`<domain>`), ours and those of
///    services everybody uses aside.
///
/// It masks whether or not recording mode is on, and it errs on the side of
/// taking out too much: a word lost from a message costs a question, a name
/// let through cannot be taken back.
abstract final class ReportScrub {
  static final List<({String path, RegExp pattern, String token})> _folders = [];

  /// Says that [path] is the folder a report calls [token] (`<app data>`,
  /// `<documents>`). The path holds the name of the person's account on the
  /// computer; the token does not, and says more.
  static void registerFolder(String path, String token) {
    var clean = path.trim();
    while (clean.length > 1 && (clean.endsWith('/') || clean.endsWith(r'\'))) {
      clean = clean.substring(0, clean.length - 1);
    }
    // (Never a drive or a root: everything would be under it.)
    if (clean.length < 4 || !token.startsWith('<') || !token.endsWith('>')) return;
    _folders.removeWhere((f) => f.path == clean);
    final parts = clean.split(RegExp(r'[\\/]'));
    final pattern = RegExp(
      parts.map(RegExp.escape).join(r'[\\/]'),
      caseSensitive: false,
    );
    _folders
      ..add((path: clean, pattern: pattern, token: token))
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
  }

  /// Forgets the folders, hosts and usernames it was told about (tests).
  static void clearFolders() {
    _folders.clear();
    forgetNames();
  }

  /// Forgets the hosts and usernames it was told about: they are a person's,
  /// and go at each change of profile (forgetWhatLivesOutsideTheAppState), so
  /// that a report is never scrubbed of another profile's names, nor says by
  /// what it takes out that they are there. The next profile's are given as
  /// its lists load (redactionFleetRegistrar). The folders are the device's,
  /// and stay.
  static void forgetNames() {
    _hosts.clear();
    _users.clear();
    _knownPattern = null;
  }

  // ── Names the app knows (3.4 security review) ──────────────────

  static final Set<String> _hosts = {};
  static final Set<String> _users = {};
  static RegExp? _knownPattern;

  /// Accounts every server has: they say nothing of whose it is, and are
  /// words a report needs ("permission denied for root").
  static const _everyServersUsers = {
    'root', 'admin', 'administrator', 'ubuntu', 'debian', 'centos', 'fedora', 'ec2-user', 'pi', 'user', //
    'guest', 'git', 'www-data', 'nobody', 'oracle', 'postgres', 'mysql', 'test', 'opc', 'azureuser', //
  };

  /// Says that [names] are hosts the app keeps (their labels and addresses):
  /// wherever one stands in a report, quoted or not, it is `<host>`.
  static void registerHosts(Iterable<String> names) {
    for (final n in names) {
      final c = n.trim();
      if (c.length >= 2 && _hosts.add(c)) _knownPattern = null;
    }
  }

  /// Says that [names] are usernames the app signs in with: wherever one
  /// stands by itself it is `<user>`. An account every server has, and one
  /// shorter than three letters, is left: it names nobody, and would take
  /// words out.
  static void registerUsernames(Iterable<String> names) {
    for (final n in names) {
      final c = n.trim();
      if (c.length < 3 || _everyServersUsers.contains(c.toLowerCase())) continue;
      if (_users.add(c)) _knownPattern = null;
    }
  }

  static String _known(String text) {
    if (_hosts.isEmpty && _users.isEmpty) return text;
    final names = [..._hosts, ..._users]..sort((a, b) => b.length.compareTo(a.length));
    final pattern = _knownPattern ??= RegExp(
      '(?<![A-Za-z0-9_.@-])(${names.map(RegExp.escape).join('|')})(?![A-Za-z0-9_-]|\\.[A-Za-z0-9])',
    );
    return text.replaceAllMapped(pattern, (m) => _hosts.contains(m[1]) ? '<host>' : '<user>');
  }

  // What is settled is set aside under a number between two characters no
  // text holds, so that a later step does not look at it again: a path that
  // was cleared must not have its file name taken for a host.
  static final String _open = String.fromCharCode(0xe000);
  static final String _close = String.fromCharCode(0xe001);
  static final RegExp _settled = RegExp('$_open(\\d+)$_close');

  /// [text] with everything named above taken out.
  static String scrub(String text) {
    if (text.isEmpty) return text;
    final kept = <String>[];
    String keep(String s) {
      kept.add(s);
      return '$_open${kept.length - 1}$_close';
    }

    var out = text.replaceAll(_open, '').replaceAll(_close, '');
    out = _secrets(out);
    out = out.replaceAllMapped(_url, (m) => _webAddress(m, keep));
    out = _paths(out, keep);
    out = out.replaceAllMapped(_run, (m) => _readsAsData(m[0]!) ? '[data removed]' : m[0]!);
    out = out.replaceAllMapped(_fileName, (m) => _bareFile(m, keep));
    out = out.replaceAllMapped(_sourceName, (m) => keep(m[0]!));
    out = _known(out);
    out = Redactor.line(out);
    out = out.replaceAllMapped(_domain, _bareDomain);
    // (What was set aside may itself hold something set aside before it.)
    for (var i = 0; i <= kept.length && _settled.hasMatch(out); i++) {
      out = out.replaceAllMapped(_settled, (m) => kept[int.parse(m[1]!)]);
    }
    return out;
  }

  // ── Secrets ───────────────────────────────────────────────────────

  static final RegExp _privateKey = RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)',
  );
  static final RegExp _puttyKey = RegExp(r'PuTTY-User-Key-File-\d+:[\s\S]*?(?:Private-MAC: *\S+|$)');
  static final RegExp _publicKey = RegExp(
    r'\b(?:ssh-(?:rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9-]+@openssh\.com)'
    r'(?:-cert-v01@openssh\.com)? AAAA[0-9A-Za-z+/]+={0,3}(?:[ \t]+[^\s]+)?',
  );
  static final RegExp _header = RegExp(
    r'\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key)(\s*:\s*)[^\r\n]+',
    caseSensitive: false,
  );
  static final RegExp _scheme = RegExp(r'\b(Bearer\s+[A-Za-z0-9._~+/=-]{6,}|Basic\s+[A-Za-z0-9._~+/=-]{8,})');

  // Every PEM block: a certificate or a request names its owner, a key is a
  // secret (a private key is said as one, above).
  static final RegExp _pem = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----[\s\S]*?(?:-----END \1-----|$)');

  // Tokens known by how they begin: Slack's, Stripe's, GitHub's and an AWS
  // access key's.
  static final RegExp _knownToken = RegExp(
    r'\b(?:xox[abposr]-[A-Za-z0-9-]{8,}|(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}'
    r'|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b',
  );

  // What follows a word that calls it a secret with only a blank between
  // ("password hunter2 rejected"), unless it is a word a message goes on
  // with ("the password was wrong").
  static final RegExp _spacedSecret = RegExp(
    r'''\b((?:[A-Za-z0-9]+[_-])*(?:pass(?:word|phrase|wd)?|pwd|secret|token|totp))\b([ \t]+)("[^"\r\n]*"|'[^'\r\n]*'|(?=[^\s,;&)\]}"'<\[]*[A-Za-z0-9])[^\s,;&)\]}"'<\[]+)''',
    caseSensitive: false,
  );
  static const _goesOn = {
    'is', 'was', 'were', 'are', 'be', 'been', 'for', 'not', 'no', 'of', 'and', 'or', 'the', 'a', 'an', 'to', //
    'from', 'with', 'will', 'would', 'has', 'have', 'had', 'may', 'must', 'can', 'cannot', 'could', 'should', //
    'did', 'does', 'do', 'on', 'in', 'at', 'by', 'as', 'if', 'that', 'this', 'it', 'its', 'so', 'but', 'then', //
    'authentication', 'auth', 'prompt', 'prompts', 'required', 'rejected', 'refused', 'incorrect', 'wrong', //
    'invalid', 'accepted', 'failed', 'fails', 'failure', 'changed', 'change', 'expired', 'expires', 'dialog', //
    'field', 'fields', 'manager', 'managers', 'login', 'set', 'saved', 'stored', 'missing', 'empty', 'too', //
    'policy', 'reset', 'entry', 'needed', 'length', 'mismatch', 'ok', 'asked', 'given', 'sent', 'typed', //
    'cleared', 'removed', 'refresh', 'refreshed', 'revoked', 'issued', 'endpoint', 'type', 'request', //
    'response', 'store', 'cache', 'service', 'storage', 'was.', 'and/or', 'here', 'there', 'again', 'only', //
    'used', 'use', 'kept', 'none', 'unknown', 'not.', 'please', 'when', 'while', 'after', 'before', 'until', //
  };

  // A one-time code after the word for it ("totp 123456", "code: 12345678").
  static final RegExp _oneTimeCode = RegExp(
    r'\b(code|otp|totp|2fa|mfa|pin)\b([\s:=#]*(?:is[ \t]+)?)(\d{6}(?:\d{2})?)\b',
    caseSensitive: false,
  );
  static final RegExp _field = RegExp(
    r'\b((?:[A-Za-z0-9]+[_-])*(?:pass(?:word|phrase|wd)?|pwd|secret|token|api[_-]?key|otp|private[_-]?key))'
    // (What was taken out before is not taken out again.)
    r'''("?\s*[=:]\s*)(?!\[removed\])("[^"\r\n]*"?|'[^'\r\n]*'?|[^\s,;&)\]}"']+)''',
    caseSensitive: false,
  );
  static final RegExp _jwt = RegExp(r'\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}');
  static final RegExp _sha256 = RegExp(r'\bSHA256:[A-Za-z0-9+/]{43}=?');
  static final RegExp _md5 = RegExp(r'\b(?:[0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2}\b');

  static String _secrets(String text) => text
      .replaceAll(_privateKey, '[private key removed]')
      .replaceAll(_puttyKey, '[private key removed]')
      .replaceAll(_pem, '[PEM block removed]')
      .replaceAll(_publicKey, '[public key removed]')
      .replaceAllMapped(_header, (m) => '${m[1]}${m[2]}[removed]')
      .replaceAllMapped(_scheme, (m) => '${m[1]!.split(RegExp(r'\s')).first} [removed]')
      .replaceAllMapped(_field, (m) => '${m[1]}${m[2]}[removed]')
      .replaceAllMapped(_spacedSecret,
          (m) => _goesOn.contains(m[3]!.toLowerCase()) ? m[0]! : '${m[1]}${m[2]}[removed]')
      .replaceAllMapped(_oneTimeCode, (m) => '${m[1]}${m[2]}[code removed]')
      .replaceAll(_knownToken, '[token removed]')
      .replaceAll(_jwt, '[token removed]')
      .replaceAll(_sha256, 'SHA256:[removed]')
      .replaceAll(_md5, '[fingerprint removed]');

  // A run of twenty or more of the characters keys and tokens are written
  // in (forty let a 32-character key through: the 3.4 security review).
  // Words, names of things in code and plain paths are such runs too: what
  // tells data from them is that it mixes capitals, small letters and
  // digits, or is all hexadecimal.
  static final RegExp _run = RegExp(r'(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{20,}={0,2}(?![A-Za-z0-9+/=_-])');
  static final RegExp _hex = RegExp(r'^[0-9a-fA-F]+$');
  static final RegExp _capital = RegExp('[A-Z]');
  static final RegExp _small = RegExp('[a-z]');
  static final RegExp _digit = RegExp('[0-9]');

  static bool _readsAsData(String run) {
    if (_hex.hasMatch(run)) return true;
    final digits = _digit.allMatches(run).length;
    if (digits == 0 || !_capital.hasMatch(run) || !_small.hasMatch(run)) return false;
    // (A path may hold a digit or two; data holds many.)
    return !run.contains('/') || digits >= 4;
  }

  // ── Web addresses ─────────────────────────────────────────────────

  static final RegExp _url = RegExp(
    r'''\b([A-Za-z][A-Za-z0-9+.-]{1,15})://([^\s/?#"'<>()]*)([^\s?#"'<>()]*)(\?[^\s#"'<>()]*)?(#[^\s"'<>()]*)?''',
  );

  /// The build's own (the release's: zestssh.com and what is under it): what
  /// is asked of them names nothing of the person's.
  static List<String> get _ours => [
        for (final host in {kZestWebsiteHost, kZestApiHost, kZestDocsHost, kZestUpdateHost})
          if (host != '') host,
      ];

  /// Services everybody uses. Their name says which service failed; what was
  /// asked of them may name a file or an account, and goes.
  static const _everybodys = [
    'googleapis.com',
    'google.com',
    'apple.com',
    'icloud.com',
    'microsoft.com',
    'microsoftonline.com',
    'live.com',
    'dropbox.com',
    'dropboxapi.com',
    'revenuecat.com',
    'github.com',
    'discord.com',
  ];

  static bool _under(String host, List<String> domains) {
    final h = host.toLowerCase();
    return domains.any((d) => h == d || h.endsWith('.$d'));
  }

  static final RegExp _drivePath = RegExp(r'^/[A-Za-z]:[\\/]');

  static String _webAddress(Match m, String Function(String) keep) {
    final scheme = m[1]!.toLowerCase();
    var authority = m[2]!;
    final path = m[3]!;
    // A file by its address is a path: the folders are looked at below.
    if (scheme == 'file') return _drivePath.hasMatch(path) ? path.substring(1) : path;
    // (Who signs in there, and with what, goes in any case.)
    final at = authority.lastIndexOf('@');
    if (at >= 0) authority = authority.substring(at + 1);
    final bracket = authority.startsWith('[') ? authority.indexOf(']') : -1;
    final colon = authority.lastIndexOf(':');
    final host = bracket > 0
        ? authority.substring(1, bracket)
        : (colon > 0 ? authority.substring(0, colon) : authority);
    final more = path.length > 1 || m[4] != null || m[5] != null;
    if (_under(host, _ours)) {
      return keep('$scheme://$authority$path${m[4] != null ? '?[removed]' : ''}');
    }
    if (_under(host, _everybodys)) {
      return '${keep('$scheme://$authority')}${more ? '/[removed]' : ''}';
    }
    if (authority.isEmpty) return '$scheme://${more ? '[removed]' : ''}';
    // (A stand-in from an earlier pass stays the stand-in it is.)
    final standIn = host.endsWith('.example.invalid') || host.startsWith('192.0.2.') || host.startsWith('2001:db8::');
    final masked = standIn ? authority : Redactor.address(authority);
    return '${keep('$scheme://$masked')}${more ? '/[removed]' : ''}';
  }

  // ── Folders and files ─────────────────────────────────────────────

  static final RegExp _windowsUser = RegExp(r'''([A-Za-z]:[\\/]Users[\\/])([^\\/\r\n:*?"'<>|]+)''', caseSensitive: false);
  static final RegExp _posixUser = RegExp(r'''(/(?:home|Users)/)([^/\r\n:*?"'<>|]+)''');
  static final RegExp _share = RegExp(r'\\\\[^\\\s]+\\');
  // A path as Windows writes it: from a drive, from a folder the app was
  // told about, or from a share. Its names may hold blanks.
  static final RegExp _windowsPath = RegExp(
    r'''(?:[A-Za-z]:(?=[\\/])|<[a-z ]+>(?=\\)|\\\\<server>)(?:[\\/][^\\/\r\n:*?"'|,;]+)+[\\/]?''',
  );
  // A path as every other system writes it. Its names hold no blanks (the
  // words after a path would be taken for part of it), the one folder aside
  // that every Mac and iPhone has with a blank in its name.
  static final RegExp _posixPath = RegExp(
    r'''(?<![A-Za-z0-9._~<>/\\-])(?:~|<[a-z ]+>)?(?:/(?:Application Support|[^/\s:*?"'|,;()\[\]{}=]+))+/?''',
  );

  /// The folders every computer has: their names say nothing of anyone.
  static const _everyComputers = {
    'users', 'home', 'root', 'windows', 'system32', 'program files', 'program files (x86)', 'programdata', //
    'appdata', 'local', 'locallow', 'roaming', 'temp', 'tmp', 'documents', 'downloads', 'desktop', 'library', //
    'application support', 'caches', 'containers', 'data', 'user', '0', 'storage', 'emulated', 'android', //
    'files', 'cache', 'app_flutter', 'databases', 'var', 'mobile', 'private', 'usr', 'bin', 'sbin', 'etc', //
    'opt', 'lib', 'lib64', 'share', 'mnt', 'media', 'proc', 'sys', 'dev', 'run', 'snap', 'srv', '.ssh', //
    '.config', '.local', '.cache', 'zestssh', 'com.affluentlabs.zestssh', 'flutter_assets', 'assets', //
    'packages', 'backups', 'logs',
  };

  /// Files the app itself writes or reads under these very names.
  static const _ownFiles = {
    'zestssh.db', 'zestssh.exe', 'known_hosts', 'config', 'authorized_keys', 'id_rsa', 'id_ed25519', //
    'id_ecdsa', 'id_dsa', 'latest.json', 'pubspec.yaml',
  };

  /// What a file is, said by the end of its name, is kept where its name is not.
  static const _kinds = {
    'db', 'sqlite', 'json', 'zest', 'txt', 'log', 'pem', 'pub', 'ppk', 'key', 'yaml', 'yml', 'conf', //
    'cfg', 'ini', 'png', 'jpg', 'jpeg', 'pdf', 'csv', 'zip', 'gz', 'tar', 'bak', 'tmp', 'lock', 'exe', //
    'dll', 'so', 'dylib', 'arb', 'cast', 'sh', 'bash', 'zsh', 'ps1', 'bat', 'py', 'rb', 'js', //
    'ts', 'java', 'php', 'sql', 'xml', 'html', 'htm', 'toml', 'crt', 'cer', 'csr', //
    'p12', 'pfx', 'jks', 'ovpn', 'xlsx', 'xls', 'docx', 'pptx', 'odt', 'ods', 'rtf', 'tgz', 'bz2', //
    'xz', 'zst', '7z', 'rar', 'deb', 'rpm', 'msi', 'dmg', 'iso', 'vmdk', 'qcow2', 'ova', 'mp4', 'mov', //
    'svg', 'gif', 'webp', 'heic', 'kdbx',
  };

  // A web domain written by itself, with one dot or more ("acme-billing.com",
  // "db.corp.lan"): known by its last part, so a version ("3.0.0"), a name in
  // code ("SftpService.open") and a file stay.
  static final RegExp _domain = RegExp(
    r'(?<![A-Za-z0-9_.@/\\<>:-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,13}))(?![A-Za-z0-9_-]|\.[A-Za-z0-9])',
  );
  static const _topLevel = {
    'com', 'net', 'org', 'io', 'dev', 'app', 'co', 'ai', 'me', 'us', 'uk', 'de', 'fr', 'nl', 'eu', 'ca', 'au', //
    'in', 'jp', 'cn', 'ru', 'br', 'it', 'es', 'ch', 'se', 'no', 'dk', 'fi', 'pl', 'cz', 'at', 'be', 'ie', 'nz', //
    'za', 'kr', 'tw', 'hk', 'sg', 'mx', 'ar', 'pt', 'gr', 'tr', 'il', 'ua', 'ro', 'hu', 'info', 'biz', 'xyz', //
    'online', 'site', 'cloud', 'tech', 'sh', 'gg', 'tv', 'cc', 'ly', 'to', 'so', 'is', 'gov', 'edu', 'mil', //
    'int', 'name', 'pro', 'host', 'network', 'systems', 'company', 'services', 'local', 'lan', 'internal', //
    'home', 'arpa', 'corp', 'intranet', 'localdomain', 'priv', 'private', 'office', 'cluster', 'svc', //
  };

  static String _bareDomain(Match m) {
    final whole = m[1]!;
    if (!_topLevel.contains(m[2]!.toLowerCase())) return whole;
    if (_under(whole, _ours) || _under(whole, _everybodys)) return whole;
    return '<domain>';
  }

  static String _paths(String text, String Function(String) keep) {
    var out = text;
    for (final f in _folders) {
      out = out.replaceAll(f.pattern, f.token);
    }
    out = out
        .replaceAllMapped(_windowsUser, (m) => '${m[1]}<user>')
        .replaceAllMapped(_posixUser, (m) => '${m[1]}<user>')
        .replaceAll(_share, r'\\<server>\');
    out = out.replaceAllMapped(_windowsPath, (m) {
      final (path, rest) = _withoutWhatFollows(m[0]!);
      return '${keep(_cleared(path, RegExp(r'[\\/]')))}$rest';
    });
    return out.replaceAllMapped(_posixPath, (m) => keep(_cleared(m[0]!, RegExp('/'))));
  }

  /// A Windows path's last name may hold blanks, so the words after a path
  /// on the same line look like part of it. Where the last name begins with
  /// something that is plainly a file or a folder every computer has, the
  /// path ends there, and the rest is given back to be read as text.
  static (String, String) _withoutWhatFollows(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]')) + 1;
    final last = path.substring(cut);
    var at = last.indexOf(' ');
    while (at > 0) {
      final head = last.substring(0, at);
      final lower = head.toLowerCase();
      final dot = lower.lastIndexOf('.');
      final kind = dot > 0 ? lower.substring(dot + 1) : '';
      if (_everyComputers.contains(lower) || _ownFiles.contains(lower) || kind == 'dart' || _kinds.contains(kind)) {
        return (path.substring(0, cut + at), last.substring(at));
      }
      at = last.indexOf(' ', at + 1);
    }
    return (path, '');
  }

  static final RegExp _token = RegExp(r'^<[a-z ]+>$');
  static final RegExp _drive = RegExp(r'^[A-Za-z]:$');
  static final RegExp _settledOnly = RegExp('^$_open\\d+$_close\$');

  /// [path] with every name in it that a person gave something taken out.
  static String _cleared(String path, RegExp separator) {
    final out = StringBuffer();
    var at = 0;
    for (final sep in separator.allMatches(path)) {
      out
        ..write(_segment(path.substring(at, sep.start)))
        ..write(sep[0]);
      at = sep.end;
    }
    out.write(_segment(path.substring(at)));
    return out.toString();
  }

  static String _segment(String raw) {
    final name = raw.trim();
    if (name.isEmpty || name == '~' || name == '.' || name == '..') return raw;
    // (A share's `\\<server>` comes here split at its backslashes: its
    // `<server>` is a token.)
    if (_token.hasMatch(name) || _drive.hasMatch(name)) return name;
    // (Something settled before, standing where a name would.)
    if (_settledOnly.hasMatch(name)) return name;
    final lower = name.toLowerCase();
    if (_everyComputers.contains(lower) || _ownFiles.contains(lower)) return name;
    final dot = lower.lastIndexOf('.');
    final kind = dot > 0 ? lower.substring(dot + 1) : '';
    // (The app's own source, in a stack: its files are named for what they do.)
    if (kind == 'dart') return name;
    return _kinds.contains(kind) ? '<file>.$kind' : '<name>';
  }

  // A file named by itself, with no folder before it.
  static final RegExp _fileName = RegExp(
    r'''(?<![A-Za-z0-9._<>/\\-])([^\s\\/:*?"'<>|,;()\[\]{}=]+)\.([A-Za-z0-9]{2,5})(?![A-Za-z0-9._-])''',
  );

  static String _bareFile(Match m, String Function(String) keep) {
    final kind = m[2]!.toLowerCase();
    final whole = m[0]!;
    if (_ownFiles.contains(whole.toLowerCase())) return keep(whole);
    return _kinds.contains(kind) ? keep('<file>.$kind') : whole;
  }

  // Where in the app's code something happened (the lines of a stack), and
  // the name the systems know the app by.
  static final RegExp _sourceName = RegExp(
    r'\b(?:package|dart):[A-Za-z0-9_./-]+|\b[A-Za-z0-9_]+(?:\.[a-z]+)*\.dart\b|\bcom\.affluentlabs\.zestssh\b',
  );
}
