/// Low-level parser for OpenSSH config file format.
///
/// Handles `Host` blocks with directives like HostName, Port, User,
/// IdentityFile, ProxyJump, etc. Wildcard blocks (`Host *`) are parsed as
/// any other: what they say holds for every host they match ([valuesFor]).
class SshConfigParser {
  /// Parse SSH config content into a list of directive maps, in the file's
  /// order.
  ///
  /// Each map represents one `Host` block with key-value pairs for
  /// directives found within that block. Of a directive written twice in a
  /// block the first is kept, as OpenSSH takes the first value it gets.
  /// What stands before the first `Host` line holds for every host: it comes
  /// as a block of `Host *`, marked with [global].
  static List<Map<String, String>> parse(String content) {
    final blocks = <Map<String, String>>[];
    Map<String, String>? currentBlock;

    for (var line in content.split(RegExp(r'\r\n|\r|\n'))) {
      line = line.trim();

      // Skip comments and empty lines
      if (line.isEmpty || line.startsWith('#')) continue;

      final split = _keyAndValue(line);
      if (split == null) continue;
      final (key, value) = split;

      if (key.toLowerCase() == 'host') {
        // Start a new block
        currentBlock = {'Host': value};
        blocks.add(currentBlock);
      } else if (key.toLowerCase() == 'match') {
        // Match blocks are more complex - treat as separate block
        currentBlock = {'Match': value};
        blocks.add(currentBlock);
      } else {
        if (currentBlock == null) {
          currentBlock = {'Host': '*', global: ''};
          blocks.add(currentBlock);
        }
        // Normalise common directive names to canonical casing
        final normalised = _normaliseKey(key);
        currentBlock.putIfAbsent(normalised, () => value);
      }
    }

    return blocks;
  }

  /// The key that marks the block of what stood before the first `Host` line.
  static const global = ' global';

  /// What [blocks] say for the host [alias], as OpenSSH works it out: the
  /// blocks are gone through in the file's order, a `Host` block counts
  /// where one of its patterns matches [alias] and none of its negated
  /// patterns (`!name`) does, and of each directive the first value found is
  /// the one that holds. `Match` blocks are left out: what they ask (a
  /// command's answer, the local user) is not known here.
  ///
  /// For many hosts of one file, make a [SshConfigIndex] once and ask it.
  static Map<String, String> valuesFor(List<Map<String, String>> blocks, String alias) =>
      SshConfigIndex(blocks).valuesFor(alias);

  /// Whether the `Host` line [spec] (patterns apart by white space) is for
  /// [alias]: `*` is any run of characters, `?` any one, and a pattern with
  /// `!` in front takes [alias] out where it matches.
  static bool hostMatches(String spec, String alias) {
    var matched = false;
    for (final token in spec.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final negated = token.startsWith('!');
      if (!_patternMatches(negated ? token.substring(1) : token, alias)) continue;
      if (negated) return false;
      matched = true;
    }
    return matched;
  }

  /// Whether [pattern] (with `*` and `?`) is all of [text]. By hand, two
  /// places at a time, so a pattern of many stars costs no more than the
  /// two lengths multiplied.
  static bool _patternMatches(String pattern, String text) {
    var p = 0, t = 0, star = -1, mark = 0;
    while (t < text.length) {
      if (p < pattern.length && (pattern[p] == '?' || pattern[p] == text[t])) {
        p++;
        t++;
      } else if (p < pattern.length && pattern[p] == '*') {
        star = p++;
        mark = t;
      } else if (star != -1) {
        p = star + 1;
        t = ++mark;
      } else {
        return false;
      }
    }
    while (p < pattern.length && pattern[p] == '*') {
      p++;
    }
    return p == pattern.length;
  }

  /// [line], trimmed, as its key and its value: the key ends at the first white
  /// space or `=`, and one `=` with white space around it may come between. By
  /// hand and not by a pattern: any file may come here, and a pattern with two
  /// runs of white space takes as long as their square on a line that does not
  /// match. Null for a line with nothing after its first word.
  static (String, String)? _keyAndValue(String line) {
    var end = 0;
    while (end < line.length && line.codeUnitAt(end) != _equals && !_isSpace(line.codeUnitAt(end))) {
      end++;
    }
    if (end == 0 || end == line.length) return null;
    var at = end;
    while (at < line.length && _isSpace(line.codeUnitAt(at))) {
      at++;
    }
    if (at < line.length && line.codeUnitAt(at) == _equals) at++;
    return (line.substring(0, end), line.substring(at).trim());
  }

  static const _equals = 0x3D;

  /// Whether [c] is white space, as `\s` has it.
  static bool _isSpace(int c) =>
      c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  /// Normalise directive keys to their canonical casing.
  static String _normaliseKey(String key) {
    final lower = key.toLowerCase();
    const canonical = {
      'hostname': 'HostName',
      'port': 'Port',
      'user': 'User',
      'identityfile': 'IdentityFile',
      'proxyjump': 'ProxyJump',
      'proxycommand': 'ProxyCommand',
      'localforward': 'LocalForward',
      'remoteforward': 'RemoteForward',
      'dynamicforward': 'DynamicForward',
      'serveraliveinterval': 'ServerAliveInterval',
      'serveralivecountmax': 'ServerAliveCountMax',
      'compression': 'Compression',
      'forwardagent': 'ForwardAgent',
      'addkeystoagent': 'AddKeysToAgent',
    };
    return canonical[lower] ?? key;
  }
}

/// The blocks of one config file, set out so that what the file says for a
/// host is found without going through every block for every host: a file
/// may hold thousands of each, and any file may come here.
///
/// A block whose `Host` line holds names only is found by those names. A
/// block with a pattern in it (`*`, `?`, `!`) is asked for every host; the
/// first [maxPatternBlocks] of a file are, which is far more than a config
/// written by a person holds, and the rest say nothing for any host.
class SshConfigIndex {
  SshConfigIndex(this.blocks) {
    for (var i = 0; i < blocks.length; i++) {
      final spec = blocks[i]['Host'];
      if (spec == null) continue;
      final tokens = [
        for (final t in spec.split(_space))
          if (t.isNotEmpty) t,
      ];
      if (tokens.any((t) => t.contains('*') || t.contains('?') || t.startsWith('!'))) {
        if (_patterns.length < maxPatternBlocks) _patterns.add(i);
      } else {
        for (final t in tokens) {
          (_byName[t] ??= []).add(i);
        }
      }
    }
  }

  static const maxPatternBlocks = 256;
  static final _space = RegExp(r'\s+');

  final List<Map<String, String>> blocks;
  final _byName = <String, List<int>>{};
  final _patterns = <int>[];

  final _found = <String, Map<String, String>>{};

  /// [SshConfigParser.valuesFor], for [alias]. Worked out once for a name:
  /// a file may name one host line after line.
  Map<String, String> valuesFor(String alias) => _found[alias] ??= _valuesFor(alias);

  Map<String, String> _valuesFor(String alias) {
    final named = _byName[alias] ?? const <int>[];
    final matching = [
      ...named,
      for (final i in _patterns)
        if (SshConfigParser.hostMatches(blocks[i]['Host']!, alias)) i,
    ]..sort();
    final out = <String, String>{};
    for (final i in matching) {
      for (final e in blocks[i].entries) {
        if (e.key == 'Host' || e.key == SshConfigParser.global) continue;
        out.putIfAbsent(e.key, () => e.value);
      }
    }
    return out;
  }
}
