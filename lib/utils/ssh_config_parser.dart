/// Low-level parser for OpenSSH config file format.
///
/// Handles `Host` blocks with directives like HostName, Port, User,
/// IdentityFile, ProxyJump, etc. Wildcard blocks (`Host *`) are
/// parsed but typically filtered out by the caller.
class SshConfigParser {
  /// Parse SSH config content into a list of directive maps.
  ///
  /// Each map represents one `Host` block with key-value pairs
  /// for directives found within that block.
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
      } else if (currentBlock != null) {
        // Normalise common directive names to canonical casing
        final normalised = _normaliseKey(key);
        currentBlock[normalised] = value;
      }
    }

    return blocks;
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
