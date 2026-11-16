import 'package:re_highlight/languages/apache.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/pgsql.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;

/// The languages the file editor colours (3.4): the files people edit on
/// servers, picked by the file's full name, its extension, and its `#!`
/// line. [label] is the language's own name, the same in every language,
/// except plain text, which is said in the app's language.
enum EditorLanguage {
  plainText('', null),
  nginx('nginx', 'nginx'),
  apache('Apache', 'apache'),
  systemd('systemd', 'ini'),
  dockerfile('Dockerfile', 'dockerfile'),
  yaml('YAML', 'yaml'),
  json('JSON', 'json'),
  ini('INI', 'ini'),
  toml('TOML', 'ini'),
  properties('Properties', 'properties'),
  sshConfig('SSH config', 'properties'),
  crontab('crontab', 'bash'),
  shell('Shell', 'bash'),
  python('Python', 'python'),
  javascript('JavaScript', 'javascript'),
  typescript('TypeScript', 'typescript'),
  php('PHP', 'php'),
  ruby('Ruby', 'ruby'),
  perl('Perl', 'perl'),
  lua('Lua', 'lua'),
  go('Go', 'go'),
  rust('Rust', 'rust'),
  html('HTML', 'xml'),
  xml('XML', 'xml'),
  css('CSS', 'css'),
  markdown('Markdown', 'markdown'),
  sql('SQL', 'sql'),
  postgresql('PostgreSQL', 'ini'),
  makefile('Makefile', 'makefile'),
  diff('Diff', 'diff');

  const EditorLanguage(this.label, this.mode);

  /// Its name ('' for plain text, which the screen says in the app's
  /// language).
  final String label;

  /// The highlighter's name for it, or null for none.
  final String? mode;

  /// What Tab and a new line's indent are by default for this kind of file,
  /// before the file's own indentation is looked at: YAML may hold no tab,
  /// a Makefile needs them, and the rest follow what is usual for them.
  EditorIndent get defaultIndent => switch (this) {
        yaml || json || javascript || typescript || ruby || html || xml || css || markdown => const EditorIndent.spaces(2),
        makefile || go => const EditorIndent.tabs(),
        _ => const EditorIndent.spaces(4),
      };

  /// Whether a tab may stand in its indentation at all.
  bool get allowsTabs => this != yaml;
}

/// How a file is indented: tabs, or a number of spaces.
class EditorIndent {
  const EditorIndent.spaces(this.size) : tabs = false;
  const EditorIndent.tabs()
      : tabs = true,
        size = 4;

  final bool tabs;

  /// Spaces per level (for a file in tabs, how wide a tab is drawn).
  final int size;

  @override
  bool operator ==(Object other) => other is EditorIndent && other.tabs == tabs && other.size == size;

  @override
  int get hashCode => Object.hash(tabs, size);

  /// How a file indents, from its first indented lines, else [fallback]: a
  /// file indented with tabs keeps tabs, one with spaces the smallest step
  /// of its indented lines (2, 4 or 8).
  static EditorIndent detect(String text, EditorLanguage language) {
    var tabbed = 0;
    var spaced = 0;
    final steps = <int, int>{};
    var seen = 0;
    var prev = 0;
    for (final line in text.split('\n')) {
      if (seen > 400) break;
      if (line.trim().isEmpty) continue;
      seen++;
      if (line.startsWith('\t')) {
        tabbed++;
        continue;
      }
      var n = 0;
      while (n < line.length && line.codeUnitAt(n) == 0x20) {
        n++;
      }
      if (n > 0) spaced++;
      final step = (n - prev).abs();
      if (step == 2 || step == 4 || step == 8) steps[step] = (steps[step] ?? 0) + 1;
      prev = n;
    }
    if (tabbed > spaced && language.allowsTabs) return const EditorIndent.tabs();
    if (spaced == 0 || steps.isEmpty) return language.defaultIndent;
    final best = steps.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    return EditorIndent.spaces(best);
  }
}

abstract final class EditorLanguages {
  /// The language of a file called [fileName] at [path] whose text starts
  /// with [firstLine]: its full name first (nginx.conf, Dockerfile,
  /// sshd_config, a crontab), then where it sits (/etc/nginx/,
  /// /etc/systemd/), then its extension, then its `#!` line.
  static EditorLanguage detect(String fileName, {String path = '', String firstLine = ''}) {
    final name = fileName.toLowerCase();
    final where = path.toLowerCase();
    // Full names.
    if (name == 'dockerfile' || name.startsWith('dockerfile.') || name.endsWith('.dockerfile') || name == 'containerfile') {
      return EditorLanguage.dockerfile;
    }
    if (name == 'makefile' || name == 'gnumakefile' || name.endsWith('.mk')) return EditorLanguage.makefile;
    if (name == 'nginx.conf' || where.contains('/nginx/')) return EditorLanguage.nginx;
    if (name == 'httpd.conf' || name == 'apache2.conf' || name == '.htaccess' || where.contains('/apache2/') || where.contains('/httpd/')) {
      return EditorLanguage.apache;
    }
    if (name == 'ssh_config' || name == 'sshd_config' || where.endsWith('/.ssh/config') || where.contains('/sshd_config.d/') ||
        where.contains('/ssh_config.d/')) {
      return EditorLanguage.sshConfig;
    }
    if (name == 'crontab' || where.contains('/cron.d/') || where.contains('/crontabs/')) return EditorLanguage.crontab;
    if (name == 'postgresql.conf' || name == 'pg_hba.conf' || name == 'pg_ident.conf') return EditorLanguage.postgresql;
    if (name.startsWith('docker-compose') || name.startsWith('compose.')) {
      if (name.endsWith('.yml') || name.endsWith('.yaml')) return EditorLanguage.yaml;
    }
    if (const {'.bashrc', '.bash_profile', '.bash_aliases', '.profile', '.zshrc', '.zprofile', '.bash_logout', '.kshrc', '.envrc'}
        .contains(name)) {
      return EditorLanguage.shell;
    }
    const units = {'service', 'socket', 'timer', 'mount', 'automount', 'target', 'path', 'slice', 'network', 'netdev', 'link'};
    final dot = name.lastIndexOf('.');
    final ext = dot <= 0 ? '' : name.substring(dot + 1);
    if (units.contains(ext) && (where.contains('/systemd/') || ext == 'service' || ext == 'timer' || ext == 'socket')) {
      return EditorLanguage.systemd;
    }
    final byExt = switch (ext) {
      'yml' || 'yaml' => EditorLanguage.yaml,
      'json' || 'jsonc' || 'json5' => EditorLanguage.json,
      'ini' || 'cfg' || 'cnf' => EditorLanguage.ini,
      'conf' => where.contains('/systemd/') ? EditorLanguage.systemd : EditorLanguage.ini,
      'toml' => EditorLanguage.toml,
      'properties' || 'env' => EditorLanguage.properties,
      'sh' || 'bash' || 'zsh' || 'ksh' => EditorLanguage.shell,
      'py' || 'pyw' => EditorLanguage.python,
      'js' || 'mjs' || 'cjs' => EditorLanguage.javascript,
      'ts' || 'tsx' => EditorLanguage.typescript,
      'php' => EditorLanguage.php,
      'rb' => EditorLanguage.ruby,
      'pl' || 'pm' => EditorLanguage.perl,
      'lua' => EditorLanguage.lua,
      'go' => EditorLanguage.go,
      'rs' => EditorLanguage.rust,
      'html' || 'htm' => EditorLanguage.html,
      'xml' || 'svg' || 'plist' => EditorLanguage.xml,
      'css' => EditorLanguage.css,
      'md' || 'markdown' => EditorLanguage.markdown,
      'sql' => EditorLanguage.sql,
      'diff' || 'patch' => EditorLanguage.diff,
      _ => null,
    };
    if (byExt != null) return byExt;
    // The `#!` line.
    if (firstLine.startsWith('#!')) {
      final l = firstLine.toLowerCase();
      if (l.contains('python')) return EditorLanguage.python;
      if (l.contains('node')) return EditorLanguage.javascript;
      if (l.contains('perl')) return EditorLanguage.perl;
      if (l.contains('ruby')) return EditorLanguage.ruby;
      if (l.contains('php')) return EditorLanguage.php;
      if (l.contains('lua')) return EditorLanguage.lua;
      if (RegExp(r'\b(ba|z|k|da|a)?sh\b').hasMatch(l)) return EditorLanguage.shell;
    }
    return EditorLanguage.plainText;
  }

  /// The highlighter's modes, by name, for every language the editor
  /// colours.
  static final Map<String, Mode> modes = {
    'nginx': langNginx,
    'apache': langApache,
    'ini': langIni,
    'dockerfile': langDockerfile,
    'yaml': langYaml,
    'json': langJson,
    'properties': langProperties,
    'bash': langBash,
    'python': langPython,
    'javascript': langJavascript,
    'typescript': langTypescript,
    'php': langPhp,
    'ruby': langRuby,
    'perl': langPerl,
    'lua': langLua,
    'go': langGo,
    'rust': langRust,
    'xml': langXml,
    'css': langCss,
    'markdown': langMarkdown,
    'sql': langSql,
    'pgsql': langPgsql,
    'makefile': langMakefile,
    'diff': langDiff,
  };
}
