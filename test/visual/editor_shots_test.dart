import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import '../helpers/code_editor_text.dart';
import '../helpers/fake_editor_source.dart';
import 'shots_util.dart';

/// Pictures of the redesigned file editor (3.4, against its
/// design mockup), dark (Graphite with the Zest Night
/// terminal theme), on a computer and a phone. Made-up hosts and files only:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/editor_shots_test.dart
///
/// Pictures land in build/shots/editor-3.4/.
class _Drafts implements EditorDraftStore {
  final Map<String, EditorDraft> kept = {};

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async => kept[identity];

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async => kept[identity] = draft;

  @override
  Future<void> remove(String identity, {String? team}) async => kept.remove(identity);

  @override
  Future<void> forgetOld({DateTime? now}) async {}
}

const _nginx = '''user www-data;
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    keepalive_timeout 30;
    server_tokens off;

    # App servers on the private network
    upstream app_backend {
        server 10.50.0.11:8080 max_fails=3;
        server 10.50.0.12:8080 max_fails=3;
    }

    server {
        listen 443 ssl http2;
        server_name shop.example.com;
        ssl_certificate /etc/ssl/certs/shop.pem;
        ssl_certificate_key /etc/ssl/private/shop.key;

        location / {
            proxy_pass http://app_backend;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location /static/ {
            root /srv/shop;
            expires 7d;
        }
    }

    # Send plain HTTP to HTTPS
    server {
        listen 80;
        server_name shop.example.com;
        return 301 https://\$host\$request_uri;
    }
}
''';

const _yaml = '''# Shop service settings, read at start

app:
  name: shop
  environment: production
  port: 8080
  workers: 4

database:
  host: 10.50.0.21
  port: 5432
  name: shop
  user: shop_app
  password_file: /run/secrets/db_password
  pool:
    min: 2
    max: 20
    idle_timeout: 30s

cache:
  backend: redis
  url: redis://10.50.0.31:6379/0
  ttl: 300

logging:
  level: info
  format: json
''';

const _pg = '''# PostgreSQL settings for the shop database

listen_addresses = '10.50.0.21'
port = 5432
max_connections = 100
superuser_reserved_connections = 3

# Memory
shared_buffers = 2GB
work_mem = 16MB
maintenance_work_mem = 256MB
effective_cache_size = 6GB
''';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const root = FileAccess(owner: 'root:root', mode: '644', writable: false, canSudo: true);
  const deploy = FileAccess(owner: 'deploy:deploy', mode: '644', writable: true, canSudo: true);
  const postgres = FileAccess(owner: 'postgres:postgres', mode: '644', writable: false, canSudo: true);

  setUpAll(() async {
    if (shotsEnabled) await loadShotFonts();
  });

  late _Drafts drafts;

  FakeEditorSource nginx() => FakeEditorSource('/etc/nginx/nginx.conf', text: _nginx, accessIs: root);
  FakeEditorSource yaml() => FakeEditorSource('/home/deploy/app/config.yaml', text: _yaml, accessIs: deploy);
  FakeEditorSource pg() =>
      FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: _pg, accessIs: postgres);

  /// The editor in the Graphite theme, the code in Zest Night, a window
  /// [size], with [files] open (the last in front).
  Future<GlobalKey> show(WidgetTester tester, List<FakeEditorSource> files, {Size size = const Size(1280, 800)}) async {
    L10nGlobal.update(l10n);
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          terminalThemeProvider.overrideWithValue(TerminalThemes.all[TerminalThemes.zestNight]!),
          editorDraftStoreProvider.overrideWithValue(drafts),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: ListView(children: [
                for (final f in files)
                  TextButton(
                    key: ValueKey('open ${f.identity}'),
                    onPressed: () => openInEditor(context, f),
                    child: Text(f.path),
                  ),
              ]),
            ),
          ),
        ),
      ),
    ));
    for (final f in files) {
      await openFile(tester, f);
    }
    return key;
  }

  /// Lets the highlighter (in an isolate) colour the code, then saves.
  Future<void> snap(WidgetTester tester, GlobalKey key, String name) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'editor-3.4/$name', pixelRatio: 1.5);
  }

  setUp(() => drafts = _Drafts());

  testWidgets('computer: three tabs from two hosts, find and replace open', (tester) async {
    if (!shotsEnabled) return;
    final a = nginx(), b = yaml(), c = pg();
    final key = await show(tester, [c, b, a]);
    c.connected = false;
    // nginx.conf in front, with a change, and find and replace open.
    final code = editorCode(tester);
    code.text = _nginx.replaceFirst('keepalive_timeout 30;', 'keepalive_timeout 65;');
    code.flatSelection = TextSelection.collapsed(offset: code.text.indexOf('proxy_pass') + 25);
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const ValueKey('editor-tool-find')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-find-field')), 'app_backend');
    await tester.tap(find.byKey(const ValueKey('editor-find-show-replace')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-replace-field')), 'shop_backend');
    await tester.pumpAndSettle();
    await snap(tester, key, '1-computer-tabs-find');
  });

  testWidgets('computer: the encoding picker', (tester) async {
    if (!shotsEnabled) return;
    final key = await show(tester, [nginx(), yaml()]);
    await tester.tap(find.byKey(const ValueKey('editor-status-encoding')));
    await tester.pumpAndSettle();
    await snap(tester, key, '1b-computer-encoding');
  });

  testWidgets('computer: Save as root', (tester) async {
    if (!shotsEnabled) return;
    final key = await show(tester, [yaml(), nginx()]);
    editorCode(tester).text = _nginx.replaceFirst('worker_processes auto;', 'worker_processes 4;');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('editor-save-as-root')));
    await tester.pumpAndSettle();
    await snap(tester, key, '2-computer-save-as-root');
  });

  testWidgets('computer: closing a tab with changes', (tester) async {
    if (!shotsEnabled) return;
    final b = yaml();
    final key = await show(tester, [nginx(), b]);
    editorCode(tester).text = _yaml.replaceFirst('workers: 4', 'workers: 8').replaceFirst('ttl: 300', 'ttl: 600');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(ValueKey('editor-tab-close-${b.identity}')));
    await tester.pumpAndSettle();
    await snap(tester, key, '3a-computer-save-changes');
  });

  testWidgets('computer: a draft restored', (tester) async {
    if (!shotsEnabled) return;
    final c = pg();
    drafts.kept[c.identity] = EditorDraft(
      text: _pg.replaceFirst('max_connections = 100', 'max_connections = 200 # raised from 100').replaceFirst('work_mem = 16MB', 'work_mem = 32MB'),
      encoding: 'utf8',
      lineBreak: 'lf',
      baseHash: sha256Of(utf8.encode(_pg)),
      keptAt: DateTime(2026, 11, 5, 22, 14),
    );
    final key = await show(tester, [nginx(), yaml(), c]);
    await snap(tester, key, '3b-computer-draft-restored');
  });

  testWidgets('phone: reading', (tester) async {
    if (!shotsEnabled) return;
    final key = await show(tester, [pg(), yaml(), nginx()], size: const Size(390, 844));
    await snap(tester, key, '4a-phone-reading');
  });

  testWidgets('phone: typing, the keys row above the keyboard', (tester) async {
    if (!shotsEnabled) return;
    final key = await show(tester, [pg(), yaml(), nginx()], size: const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.tap(find.byType(TextEditorScreen));
    await tester.pumpAndSettle();
    editorCode(tester).flatSelection = TextSelection.collapsed(offset: _nginx.indexOf('server {') + 8);
    await tester.pump(const Duration(milliseconds: 200));
    await snap(tester, key, '4b-phone-typing');
  });

  testWidgets('phone: typing, a message below the bar with Done, clear of the keys row', (tester) async {
    if (!shotsEnabled) return;
    debugTopSnackBarOnPhone = true;
    addTearDown(() => debugTopSnackBarOnPhone = null);
    final key = await show(tester, [pg(), yaml(), nginx()], size: const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.tap(find.byType(TextEditorScreen));
    await tester.pumpAndSettle();
    showTopSnackBar(tester.element(find.byType(TextEditorScreen)), l10n.editorSaved('nginx.conf'), isSuccess: true);
    await snap(tester, key, '4c-phone-typing-message');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('phone: the More sheet', (tester) async {
    if (!shotsEnabled) return;
    final key = await show(tester, [pg(), yaml(), nginx()], size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('editor-phone-more')));
    await tester.pumpAndSettle();
    await snap(tester, key, '5-phone-more');
  });
}
