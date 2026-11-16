import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Icon + tint pair for a file or directory entry. Returned by
/// [resolveSftpFileIcon] so the renderer can use a consistent color tier
/// across the file list (configs are amber, code is blue, archives are
/// purple, etc.) without hard-coding the mapping at the call site.
class SftpIconStyle {
  final IconData icon;
  final Color _tint;

  const SftpIconStyle(this.icon, this._tint);

  /// The glyph's colour. The shared file tone is the active theme's muted
  /// text (3.0: it follows the theme); anything else is used as given.
  Color get color=> _tint == _muted ? AppColors.onSurfaceDim : _tint;
}

/// Resolve an icon + color for a file by name. Directories are handled
/// separately by the caller (folder icons).
///
/// Resolution order:
///  1. Exact filename match (Dockerfile, Makefile, .env, package.json …)
///  2. Compound extension match (.tar.gz, .tar.bz2, …)
///  3. Single extension match
///  4. Default fallback
SftpIconStyle resolveSftpFileIcon(String fileName) {
  final lower = fileName.toLowerCase();

  // 1. Special filenames - these are recognisable on sight regardless of
  // extension. Matches case-insensitively against the full filename.
  final special = _specialFilenames[lower];
  if (special != null) return special;

  // 2. Compound extensions - must check before single ext because
  // "file.tar.gz" would otherwise resolve to .gz.
  for (final entry in _compoundExtensions.entries) {
    if (lower.endsWith(entry.key)) return entry.value;
  }

  // 3. Single extension. Treat dotfiles (".bashrc", ".gitignore") as
  // having no extension; they're handled in the special map.
  final dot = lower.lastIndexOf('.');
  if (dot > 0 && dot < lower.length - 1) {
    final ext = lower.substring(dot + 1);
    final styled = _extensions[ext];
    if (styled != null) return styled;
  }

  // 4. Default - the same muted neutral as every other file tier (an unknown
  // extension must not read as a lighter/different grey).
  return const SftpIconStyle(LucideIcons.file, _muted);
}

// File TYPE is carried by the GLYPH, not colour. Colour in this
// system already means status, tier and brand; a fourth meaning for file type
// makes all four less legible - the pink `.tar.gz` being the tell. So every
// file icon is ONE muted neutral and the glyph does the distinguishing (there
// are well over five distinct glyphs: fileCode, archive, image, fileText, file,
// key, terminal, database, braces, …). Directories keep the one type colour
// worth having - [AppColors.brandHi] - applied by the caller, not here.
/// Stands for the theme's muted text in the const tables below; [SftpIconStyle.color]
/// resolves it at paint time.
const _muted = Color(0xFF8D8B83);
const _code = _muted;
const _config = _muted;
const _docs = _muted;
const _media = _muted;
const _archive = _muted;
const _key = _muted;
const _exec = _muted;
const _data = _muted;
const _doc = _muted;
const _dim = _muted;

/// Filenames recognised on sight, independent of extension.
final Map<String, SftpIconStyle> _specialFilenames = {
  // Build / packaging
  'dockerfile': const SftpIconStyle(LucideIcons.box, _config),
  'docker-compose.yml': const SftpIconStyle(LucideIcons.boxes, _config),
  'docker-compose.yaml': const SftpIconStyle(LucideIcons.boxes, _config),
  'makefile': const SftpIconStyle(LucideIcons.hammer, _config),
  'rakefile': const SftpIconStyle(LucideIcons.hammer, _config),
  'gemfile': const SftpIconStyle(LucideIcons.gem, _config),
  'gemfile.lock': const SftpIconStyle(LucideIcons.lock, _dim),
  'pipfile': const SftpIconStyle(LucideIcons.box, _config),
  'pipfile.lock': const SftpIconStyle(LucideIcons.lock, _dim),
  'package.json': const SftpIconStyle(LucideIcons.package, _config),
  'package-lock.json': const SftpIconStyle(LucideIcons.lock, _dim),
  'yarn.lock': const SftpIconStyle(LucideIcons.lock, _dim),
  'pnpm-lock.yaml': const SftpIconStyle(LucideIcons.lock, _dim),
  'bun.lockb': const SftpIconStyle(LucideIcons.lock, _dim),
  'pubspec.yaml': const SftpIconStyle(LucideIcons.package, _config),
  'pubspec.lock': const SftpIconStyle(LucideIcons.lock, _dim),
  'cargo.toml': const SftpIconStyle(LucideIcons.package, _config),
  'cargo.lock': const SftpIconStyle(LucideIcons.lock, _dim),
  'go.mod': const SftpIconStyle(LucideIcons.package, _config),
  'go.sum': const SftpIconStyle(LucideIcons.lock, _dim),
  'composer.json': const SftpIconStyle(LucideIcons.package, _config),
  'composer.lock': const SftpIconStyle(LucideIcons.lock, _dim),

  // Env / secrets
  '.env': const SftpIconStyle(LucideIcons.key, _key),
  '.env.local': const SftpIconStyle(LucideIcons.key, _key),
  '.env.production': const SftpIconStyle(LucideIcons.key, _key),
  '.env.development': const SftpIconStyle(LucideIcons.key, _key),
  '.env.example': const SftpIconStyle(LucideIcons.key, _dim),
  '.env.sample': const SftpIconStyle(LucideIcons.key, _dim),

  // Git / VCS
  '.gitignore': const SftpIconStyle(LucideIcons.gitBranch, _dim),
  '.gitattributes': const SftpIconStyle(LucideIcons.gitBranch, _dim),
  '.gitmodules': const SftpIconStyle(LucideIcons.gitBranch, _dim),
  '.gitkeep': const SftpIconStyle(LucideIcons.gitBranch, _dim),

  // CI / editor
  '.editorconfig': const SftpIconStyle(LucideIcons.settings, _config),
  '.prettierrc': const SftpIconStyle(LucideIcons.settings, _config),
  '.eslintrc': const SftpIconStyle(LucideIcons.settings, _config),
  '.eslintrc.json': const SftpIconStyle(LucideIcons.settings, _config),
  '.eslintrc.js': const SftpIconStyle(LucideIcons.settings, _config),
  '.babelrc': const SftpIconStyle(LucideIcons.settings, _config),
  '.travis.yml': const SftpIconStyle(LucideIcons.gitMerge, _config),
  '.dockerignore': const SftpIconStyle(LucideIcons.box, _dim),
  '.npmignore': const SftpIconStyle(LucideIcons.eyeOff, _dim),

  // Shells / dotfiles
  '.bashrc': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.bash_profile': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.zshrc': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.profile': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.vimrc': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.tmux.conf': const SftpIconStyle(LucideIcons.terminal, _exec),
  '.inputrc': const SftpIconStyle(LucideIcons.terminal, _exec),

  // SSH
  'authorized_keys': const SftpIconStyle(LucideIcons.userCheck, _key),
  'known_hosts': const SftpIconStyle(LucideIcons.shieldCheck, _key),
  'ssh_config': const SftpIconStyle(LucideIcons.settings, _config),
  'sshd_config': const SftpIconStyle(LucideIcons.settings, _config),

  // Docs
  'readme': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'readme.md': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'readme.txt': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'readme.rst': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'license': const SftpIconStyle(LucideIcons.scale, _docs),
  'license.md': const SftpIconStyle(LucideIcons.scale, _docs),
  'license.txt': const SftpIconStyle(LucideIcons.scale, _docs),
  'changelog': const SftpIconStyle(LucideIcons.history, _docs),
  'changelog.md': const SftpIconStyle(LucideIcons.history, _docs),
  'contributing.md': const SftpIconStyle(LucideIcons.users, _docs),
  'todo': const SftpIconStyle(LucideIcons.checkSquare, _docs),
  'todo.md': const SftpIconStyle(LucideIcons.checkSquare, _docs),

  // System
  'hosts': const SftpIconStyle(LucideIcons.network, _config),
  'fstab': const SftpIconStyle(LucideIcons.hardDrive, _config),
  'crontab': const SftpIconStyle(LucideIcons.clock, _config),
};

/// Compound extensions - checked before single-extension. Order matters
/// for nothing since each tail is unique, but iteration order is the
/// insertion order so we keep the most common first for a small win.
final Map<String, SftpIconStyle> _compoundExtensions = {
  '.tar.gz': const SftpIconStyle(LucideIcons.archive, _archive),
  '.tar.bz2': const SftpIconStyle(LucideIcons.archive, _archive),
  '.tar.xz': const SftpIconStyle(LucideIcons.archive, _archive),
  '.tar.zst': const SftpIconStyle(LucideIcons.archive, _archive),
  '.d.ts': const SftpIconStyle(LucideIcons.fileCode, _code),
};

/// Single-extension lookups. Lowercase keys.
final Map<String, SftpIconStyle> _extensions = {
  // Code - JS family
  'js': const SftpIconStyle(LucideIcons.fileCode, _code),
  'mjs': const SftpIconStyle(LucideIcons.fileCode, _code),
  'cjs': const SftpIconStyle(LucideIcons.fileCode, _code),
  'jsx': const SftpIconStyle(LucideIcons.fileCode, _code),
  'ts': const SftpIconStyle(LucideIcons.fileCode, _code),
  'tsx': const SftpIconStyle(LucideIcons.fileCode, _code),
  // Code - web
  'html': const SftpIconStyle(LucideIcons.fileCode, _code),
  'htm': const SftpIconStyle(LucideIcons.fileCode, _code),
  'css': const SftpIconStyle(LucideIcons.fileCode, _code),
  'scss': const SftpIconStyle(LucideIcons.fileCode, _code),
  'sass': const SftpIconStyle(LucideIcons.fileCode, _code),
  'less': const SftpIconStyle(LucideIcons.fileCode, _code),
  'vue': const SftpIconStyle(LucideIcons.fileCode, _code),
  'svelte': const SftpIconStyle(LucideIcons.fileCode, _code),
  // Code - systems
  'c': const SftpIconStyle(LucideIcons.fileCode, _code),
  'h': const SftpIconStyle(LucideIcons.fileCode, _code),
  'cpp': const SftpIconStyle(LucideIcons.fileCode, _code),
  'cc': const SftpIconStyle(LucideIcons.fileCode, _code),
  'cxx': const SftpIconStyle(LucideIcons.fileCode, _code),
  'hpp': const SftpIconStyle(LucideIcons.fileCode, _code),
  'rs': const SftpIconStyle(LucideIcons.fileCode, _code),
  'go': const SftpIconStyle(LucideIcons.fileCode, _code),
  'zig': const SftpIconStyle(LucideIcons.fileCode, _code),
  'swift': const SftpIconStyle(LucideIcons.fileCode, _code),
  'kt': const SftpIconStyle(LucideIcons.fileCode, _code),
  'kts': const SftpIconStyle(LucideIcons.fileCode, _code),
  'scala': const SftpIconStyle(LucideIcons.fileCode, _code),
  'java': const SftpIconStyle(LucideIcons.fileCode, _code),
  'cs': const SftpIconStyle(LucideIcons.fileCode, _code),
  'fs': const SftpIconStyle(LucideIcons.fileCode, _code),
  'vb': const SftpIconStyle(LucideIcons.fileCode, _code),
  'dart': const SftpIconStyle(LucideIcons.fileCode, _code),
  // Code - scripting
  'py': const SftpIconStyle(LucideIcons.fileCode, _code),
  'pyc': const SftpIconStyle(LucideIcons.fileCode, _dim),
  'rb': const SftpIconStyle(LucideIcons.fileCode, _code),
  'php': const SftpIconStyle(LucideIcons.fileCode, _code),
  'lua': const SftpIconStyle(LucideIcons.fileCode, _code),
  'pl': const SftpIconStyle(LucideIcons.fileCode, _code),
  'r': const SftpIconStyle(LucideIcons.fileCode, _code),
  'jl': const SftpIconStyle(LucideIcons.fileCode, _code),
  // Shell scripts (executable feel - green)
  'sh': const SftpIconStyle(LucideIcons.terminal, _exec),
  'bash': const SftpIconStyle(LucideIcons.terminal, _exec),
  'zsh': const SftpIconStyle(LucideIcons.terminal, _exec),
  'fish': const SftpIconStyle(LucideIcons.terminal, _exec),
  'ps1': const SftpIconStyle(LucideIcons.terminal, _exec),
  'bat': const SftpIconStyle(LucideIcons.terminal, _exec),
  'cmd': const SftpIconStyle(LucideIcons.terminal, _exec),

  // Configs - yellow/amber
  'json': const SftpIconStyle(LucideIcons.braces, _config),
  'jsonc': const SftpIconStyle(LucideIcons.braces, _config),
  'json5': const SftpIconStyle(LucideIcons.braces, _config),
  'yaml': const SftpIconStyle(LucideIcons.fileText, _config),
  'yml': const SftpIconStyle(LucideIcons.fileText, _config),
  'toml': const SftpIconStyle(LucideIcons.fileText, _config),
  'xml': const SftpIconStyle(LucideIcons.code, _config),
  'ini': const SftpIconStyle(LucideIcons.fileText, _config),
  'cfg': const SftpIconStyle(LucideIcons.fileText, _config),
  'conf': const SftpIconStyle(LucideIcons.fileText, _config),
  'properties': const SftpIconStyle(LucideIcons.fileText, _config),
  'env': const SftpIconStyle(LucideIcons.key, _key),

  // Data
  'csv': const SftpIconStyle(LucideIcons.table, _data),
  'tsv': const SftpIconStyle(LucideIcons.table, _data),
  'sql': const SftpIconStyle(LucideIcons.database, _data),
  'sqlite': const SftpIconStyle(LucideIcons.database, _data),
  'sqlite3': const SftpIconStyle(LucideIcons.database, _data),
  'db': const SftpIconStyle(LucideIcons.database, _data),
  'parquet': const SftpIconStyle(LucideIcons.database, _data),
  'arrow': const SftpIconStyle(LucideIcons.database, _data),

  // Docs / markdown
  'md': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'mdx': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'rst': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'tex': const SftpIconStyle(LucideIcons.bookOpen, _docs),
  'rtf': const SftpIconStyle(LucideIcons.fileText, _docs),
  'txt': const SftpIconStyle(LucideIcons.fileText, _dim),
  'log': const SftpIconStyle(LucideIcons.scrollText, _dim),

  // Office / PDF
  'pdf': const SftpIconStyle(LucideIcons.fileText, _doc),
  'doc': const SftpIconStyle(LucideIcons.fileText, _doc),
  'docx': const SftpIconStyle(LucideIcons.fileText, _doc),
  'xls': const SftpIconStyle(LucideIcons.table, _doc),
  'xlsx': const SftpIconStyle(LucideIcons.table, _doc),
  'ppt': const SftpIconStyle(LucideIcons.presentation, _doc),
  'pptx': const SftpIconStyle(LucideIcons.presentation, _doc),
  'odt': const SftpIconStyle(LucideIcons.fileText, _doc),
  'ods': const SftpIconStyle(LucideIcons.table, _doc),
  'odp': const SftpIconStyle(LucideIcons.presentation, _doc),

  // Images
  'png': const SftpIconStyle(LucideIcons.image, _media),
  'jpg': const SftpIconStyle(LucideIcons.image, _media),
  'jpeg': const SftpIconStyle(LucideIcons.image, _media),
  'gif': const SftpIconStyle(LucideIcons.image, _media),
  'bmp': const SftpIconStyle(LucideIcons.image, _media),
  'webp': const SftpIconStyle(LucideIcons.image, _media),
  'tiff': const SftpIconStyle(LucideIcons.image, _media),
  'svg': const SftpIconStyle(LucideIcons.image, _code),
  'ico': const SftpIconStyle(LucideIcons.image, _media),
  'heic': const SftpIconStyle(LucideIcons.image, _media),

  // Video
  'mp4': const SftpIconStyle(LucideIcons.video, _media),
  'mkv': const SftpIconStyle(LucideIcons.video, _media),
  'mov': const SftpIconStyle(LucideIcons.video, _media),
  'avi': const SftpIconStyle(LucideIcons.video, _media),
  'wmv': const SftpIconStyle(LucideIcons.video, _media),
  'webm': const SftpIconStyle(LucideIcons.video, _media),
  'flv': const SftpIconStyle(LucideIcons.video, _media),
  'm4v': const SftpIconStyle(LucideIcons.video, _media),

  // Audio
  'mp3': const SftpIconStyle(LucideIcons.music, _media),
  'wav': const SftpIconStyle(LucideIcons.music, _media),
  'flac': const SftpIconStyle(LucideIcons.music, _media),
  'ogg': const SftpIconStyle(LucideIcons.music, _media),
  'aac': const SftpIconStyle(LucideIcons.music, _media),
  'm4a': const SftpIconStyle(LucideIcons.music, _media),
  'opus': const SftpIconStyle(LucideIcons.music, _media),

  // Fonts
  'ttf': const SftpIconStyle(LucideIcons.type, _media),
  'otf': const SftpIconStyle(LucideIcons.type, _media),
  'woff': const SftpIconStyle(LucideIcons.type, _media),
  'woff2': const SftpIconStyle(LucideIcons.type, _media),

  // Archives
  'zip': const SftpIconStyle(LucideIcons.archive, _archive),
  'tar': const SftpIconStyle(LucideIcons.archive, _archive),
  'gz': const SftpIconStyle(LucideIcons.archive, _archive),
  'bz2': const SftpIconStyle(LucideIcons.archive, _archive),
  'xz': const SftpIconStyle(LucideIcons.archive, _archive),
  'zst': const SftpIconStyle(LucideIcons.archive, _archive),
  '7z': const SftpIconStyle(LucideIcons.archive, _archive),
  'rar': const SftpIconStyle(LucideIcons.archive, _archive),

  // Binaries / executables
  'exe': const SftpIconStyle(LucideIcons.terminal, _exec),
  'dll': const SftpIconStyle(LucideIcons.cpu, _dim),
  'so': const SftpIconStyle(LucideIcons.cpu, _dim),
  'dylib': const SftpIconStyle(LucideIcons.cpu, _dim),
  'a': const SftpIconStyle(LucideIcons.cpu, _dim),
  'o': const SftpIconStyle(LucideIcons.cpu, _dim),
  'bin': const SftpIconStyle(LucideIcons.cpu, _dim),
  'app': const SftpIconStyle(LucideIcons.appWindow, _exec),
  'apk': const SftpIconStyle(LucideIcons.smartphone, _exec),
  'ipa': const SftpIconStyle(LucideIcons.smartphone, _exec),
  'deb': const SftpIconStyle(LucideIcons.package, _exec),
  'rpm': const SftpIconStyle(LucideIcons.package, _exec),

  // Disk images
  'iso': const SftpIconStyle(LucideIcons.disc, _archive),
  'img': const SftpIconStyle(LucideIcons.disc, _archive),
  'dmg': const SftpIconStyle(LucideIcons.disc, _archive),
  'vhd': const SftpIconStyle(LucideIcons.disc, _archive),
  'vmdk': const SftpIconStyle(LucideIcons.disc, _archive),

  // Keys / certs
  'pem': const SftpIconStyle(LucideIcons.key, _key),
  'key': const SftpIconStyle(LucideIcons.key, _key),
  'pub': const SftpIconStyle(LucideIcons.key, _key),
  'ppk': const SftpIconStyle(LucideIcons.key, _key),
  'crt': const SftpIconStyle(LucideIcons.shieldCheck, _key),
  'cer': const SftpIconStyle(LucideIcons.shieldCheck, _key),
  'p12': const SftpIconStyle(LucideIcons.shieldCheck, _key),
  'pfx': const SftpIconStyle(LucideIcons.shieldCheck, _key),
  'gpg': const SftpIconStyle(LucideIcons.lock, _key),
  'asc': const SftpIconStyle(LucideIcons.lock, _key),
};

/// Backwards-compatible shim - older call sites use the old API that
/// returns just an [IconData]. New code should call [resolveSftpFileIcon]
/// directly so it gets the matching tint.
IconData sftpFileIcon(String fileName) => resolveSftpFileIcon(fileName).icon;
