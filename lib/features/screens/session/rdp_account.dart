/// An RDP account as a person writes it in a key's user name (4.0;
/// no field of its own for the domain): `DOMAIN\user` is
/// the user in that domain, `.\user` an account of the PC itself, and
/// `user@domain` goes as it is (Windows takes it whole). Spaces around either
/// part are dropped; a name with no domain has none.
({String username, String? domain}) rdpAccount(String typed) {
  final name = typed.trim();
  final slash = name.indexOf('\\');
  if (slash <= 0) return (username: slash == 0 ? name.substring(1).trim() : name, domain: null);
  final domain = name.substring(0, slash).trim();
  final user = name.substring(slash + 1).trim();
  return (username: user, domain: domain.isEmpty ? null : domain);
}

/// An account as it is shown and logged: DOMAIN\user, or the name alone.
String rdpAccountText(String username, String? domain) =>
    domain == null || domain.isEmpty ? username : '$domain\\$username';

/// What the engine is asked to draw with for a host's Graphics choice: the
/// graphics pipeline (which falls back by itself to RemoteFX for a server
/// without it) for Auto and Modern, RemoteFX surface commands, or bitmaps.
String rdpGraphicsName(String choice) => switch (choice) {
      'remotefx' => 'remotefx',
      'basic' => 'bitmap',
      _ => 'gfx',
    };

/// Whether the engine is asked for H.264 in the graphics pipeline for a
/// host's Graphics choice: "avc444" for Modern, "off" for every other.
/// The engine has a decoder only where the system gives it one (Windows,
/// through Media Foundation, since 4.0); anywhere else it offers the server
/// no H.264 whatever this says, and Modern draws as Auto does.
///
/// Auto stays without H.264 for now: its pictures cost several times the
/// processor of RemoteFX Progressive's (the spike measured most of a core
/// against a third), which matters on a laptop's battery, and they are a
/// server's bytes handed to the system's video decoder. A person who wants
/// the sharper moving picture picks Modern for that host.
String rdpH264Name(String choice) => choice == 'modern' ? 'avc444' : 'off';
