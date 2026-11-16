/// Whether opening [path] could reach for another computer: a network path as
/// Windows reads one (`\\server\share`, `//server/share`, and the same with the
/// slashes mixed: `/\server\share`, `\/server/share`), or one through its own
/// namespaces, which get there too (`\\?\UNC\server`, `\??\UNC\server`).
///
/// Merely opening one makes Windows sign in to that server with the person's own
/// credentials, whatever the file turns out to be. So a path read from a file
/// that can come from someone else (an IdentityFile in an SSH config) is never
/// opened where this is true. On other systems such a path is local, and a config
/// has no reason to write one.
bool isNetworkPath(String path) {
  final p = path.trimLeft();
  return p.startsWith(RegExp(r'[\\/]{2}')) || p.startsWith(RegExp(r'[\\/]\?\?[\\/]'));
}
