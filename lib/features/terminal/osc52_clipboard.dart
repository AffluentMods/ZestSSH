import 'dart:convert';

/// OSC 52 ("manipulate selection data"): the way a remote program puts text
/// on the LOCAL clipboard through the terminal. tmux (`set-clipboard on`),
/// Neovim and Vim over SSH, kitty's `clipboard` kitten and the small `osc52`
/// shell helpers all emit `OSC 52 ; Pc ; Pd ST` with `Pd` the base64 text.
///
/// Write-only by design. The same sequence has a read-back form
/// (`OSC 52 ; c ; ? ST`) asking the terminal to SEND the clipboard contents
/// back to the program. ZestSSH never answers it: a remote host, or anything
/// that can print to the terminal (a `cat` of a hostile file is enough), must
/// not be able to read what the user last copied. Writes are honoured only
/// when the user turns the setting on (off by default, like xterm's own
/// `allowWindowOps`), because a remote program then decides what the next
/// paste contains.
class Osc52 {
  Osc52._();

  /// Largest base64 payload honoured. Bigger writes are IGNORED rather than
  /// truncated, so the clipboard never holds a silently cut-off value. 4 MiB
  /// of base64 is about 3 MiB of text, well past any real copy.
  static const int maxEncodedLength = 4 * 1024 * 1024;

  /// The OSC code the terminal hands to `onPrivateOSC`.
  static const String code = '52';

  /// True when [args] is the read-back query (`?`): the caller refuses it and
  /// must not reply.
  static bool isQuery(List<String> args) => args.length >= 2 && args[1] == '?';

  /// Decode the parameters of `OSC 52 ; Pc ; Pd` into the text to place on
  /// the clipboard, or null when the sequence must be ignored: the read-back
  /// query, a missing / empty / malformed payload, or an oversize one.
  ///
  /// [args] is what xterm passes after the code, so `["c", "<base64>"]`; the
  /// selection name (`c`, `p`, `s`, `0`-`7`, or empty for the default) is
  /// accepted whatever it is, because this device has exactly one clipboard
  /// (no PRIMARY / cut-buffer distinction to route to).
  static String? decode(List<String> args) {
    if (args.length < 2) return null;
    if (isQuery(args)) return null;
    final payload = args[1].trim();
    if (payload.isEmpty || payload.length > maxEncodedLength) return null;
    final List<int> bytes;
    try {
      // normalize() repairs missing padding and URL-safe alphabets, which
      // some emitters produce; anything else malformed still throws.
      bytes = base64.decode(base64.normalize(payload));
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}
