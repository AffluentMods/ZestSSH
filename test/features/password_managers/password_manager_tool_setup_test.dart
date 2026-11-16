import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_settings.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_tool_setup.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

/// A password manager's tool is set up where it is asked for (before,
/// choosing 1Password said "op is not installed where ZestSSH
/// looks. Set where it is in Settings, Password managers."): not found, the
/// key editor says so and offers Check again, Choose op.exe… and the tool's
/// own install (the command to copy, the official page) with the one step
/// after it; a file chosen is kept in the same per-device setting Settings
/// uses, only when it would run; found, one quiet line says where. Bitwarden
/// and KeePassXC the same with their own words, and Settings uses the same
/// piece.

class _Runner implements PmProcessRunner {
  @override
  Future<PmProcessResult> run(String executable, List<String> args,
          {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async =>
      const PmProcessResult(0, '[]', '');
}

class _Picker extends FilePicker {
  _Picker(this.path);

  String? path;
  String? title;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    title = dialogTitle;
    final p = path;
    return p == null ? null : FilePickerResult([PlatformFile(path: p, name: p.split(RegExp(r'[\\/]')).last, size: 0)]);
  }
}

const _local = r'C:\Users\demo\AppData\Local';
const _winget = '$_local\\Microsoft\\WinGet\\Packages\\AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\\op.exe';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late Set<String> files;
  late _Picker picker;
  late SharedPreferences prefs;

  setUp(() {
    files = <String>{};
    picker = _Picker(null);
    FilePicker.platform = picker;
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {String platform = 'windows'}) async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        passwordManagersProvider.overrideWith((ref) => PasswordManagers(
              runner: _Runner(),
              settings: () => ref.read(passwordManagerSettingsProvider),
              environment: platform == 'windows'
                  ? const {'LOCALAPPDATA': _local, 'USERPROFILE': r'C:\Users\demo', 'Path': r'C:\Windows'}
                  : const {'HOME': '/home/demo', 'PATH': '/usr/bin'},
              exists: files.contains,
              listDir: (d) => d.endsWith(r'WinGet\Packages') && files.contains(_winget)
                  ? const ['AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe']
                  : const [],
              isWindows: platform == 'windows',
              isMacOS: platform == 'macos',
            )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('not found: in the key editor itself, what to do; never a pointer to Settings', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, PasswordRefEditor(value: null, onChanged: (_) {}));
    expect(find.byKey(const ValueKey('pm-setup-op')), findsOneWidget);
    expect(find.text(l10n.pmSetupMissing('op', '1Password')), findsOneWidget);
    expect(find.text('op is not installed where ZestSSH looks. Set where it is in Settings, Password managers.'), findsNothing, reason: 'it pointed to Settings');
    expect(find.text('winget install AgileBits.1Password.CLI'), findsOneWidget);
    expect(find.text(l10n.pmSetupAfterOnePassword), findsOneWidget, reason: "the 1Password app's one setting");
    expect(find.text(l10n.pmSetupChooseFile('op.exe')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-setup-page-op')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-choose')), findsNothing, reason: 'nothing to pick with yet');

    await tap(tester, 'pm-setup-copy');
    expect(copied, 'winget install AgileBits.1Password.CLI');
    await tester.pump(const Duration(seconds: 5));

    // Bitwarden and KeePassXC with their own words.
    await tester.tap(find.text('Bitwarden'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmSetupMissing('bw', 'Bitwarden')), findsOneWidget);
    expect(find.text('choco install bitwarden-cli'), findsOneWidget);
    expect(find.text(l10n.pmSetupAfterBitwarden), findsOneWidget);
    await tester.tap(find.text('KeePassXC'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmSetupMissing('keepassxc-cli', 'KeePassXC')), findsOneWidget);
    expect(find.text('winget install -e --id KeePassXCTeam.KeePassXC'), findsOneWidget);
    expect(find.text(l10n.pmSetupChooseFile('keepassxc-cli.exe')), findsOneWidget);
  });

  testWidgets('Choose op.exe… keeps the file in the per-device setting, only when it would run', (tester) async {
    final container = await pump(tester, PasswordRefEditor(value: null, onChanged: (_) {}));

    // A .cmd would go through cmd.exe: refused, said, not kept.
    picker.path = r'D:\tools\op.cmd';
    files.add(r'D:\tools\op.cmd');
    await tap(tester, 'pm-setup-choose-op');
    expect(picker.title, l10n.pmSettingsWhereIs('op'));
    expect(find.text(l10n.pmSetupChosenNotRunnable('op.exe')), findsOneWidget);
    expect(container.read(passwordManagerSettingsProvider).paths, isEmpty);
    expect(prefs.getString('password_managers_v1'), isNull);

    picker.path = r'D:\tools\op.exe';
    files.add(r'D:\tools\op.exe');
    await tap(tester, 'pm-setup-choose-op');
    expect(container.read(passwordManagerSettingsProvider).paths[PasswordManagerKind.onePassword], r'D:\tools\op.exe');
    expect(PasswordManagerSettingsNotifier.read(prefs).paths[PasswordManagerKind.onePassword], r'D:\tools\op.exe',
        reason: 'the same setting Settings uses, on this device');
    expect(find.byKey(const ValueKey('pm-setup-op')), findsNothing);
    expect(find.text(l10n.pmToolFound('op', r'D:\tools\op.exe')), findsOneWidget, reason: 'one quiet line');
    expect(find.byKey(const ValueKey('pm-choose')), findsOneWidget, reason: 'and on to the item');
  });

  testWidgets('Check again: still nothing says so; installed, found where winget put it; a set path that no '
      'longer runs is let go of', (tester) async {
    final container = await pump(tester, PasswordRefEditor(value: null, onChanged: (_) {}));
    await tap(tester, 'pm-setup-find-op');
    expect(find.text(l10n.pmSetupStillMissing('op')), findsOneWidget);

    files.add(_winget);
    await tap(tester, 'pm-setup-find-op');
    expect(find.text(l10n.pmToolFound('op', _winget)), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-choose')), findsOneWidget);

    // Set to a file since removed: said, and Check again looks in the usual
    // places again.
    await container
        .read(passwordManagerSettingsProvider.notifier)
        .setToolPath(PasswordManagerKind.onePassword, r'D:\gone\op.exe');
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmSettingsNotRunnable(r'D:\gone\op.exe')), findsOneWidget);
    await tap(tester, 'pm-setup-find-op');
    expect(container.read(passwordManagerSettingsProvider).paths, isEmpty);
    expect(find.text(l10n.pmToolFound('op', _winget)), findsOneWidget);
  });

  testWidgets("each system's own install: Homebrew on macOS, the page alone for 1Password on Linux", (tester) async {
    await pump(tester, const PasswordManagerToolSetup(kind: PasswordManagerKind.onePassword), platform: 'macos');
    expect(find.text('brew install 1password-cli'), findsOneWidget);
    expect(find.text(l10n.pmSetupChooseFile('op')), findsOneWidget);
    await pump(tester, const PasswordManagerToolSetup(kind: PasswordManagerKind.onePassword), platform: 'linux');
    expect(find.byKey(const ValueKey('pm-setup-command')), findsNothing);
    expect(find.byKey(const ValueKey('pm-setup-page-op')), findsOneWidget);
    expect(passwordManagerInstall(PasswordManagerKind.bitwarden, 'linux').command, 'sudo snap install bw');
    expect(passwordManagerInstall(PasswordManagerKind.keePassXc, 'macos').command, 'brew install --cask keepassxc');
  });

  testWidgets('KeePassXC found with no database: chosen right there', (tester) async {
    files.add(r'C:\Users\demo\scoop\shims\keepassxc-cli.exe');
    final container = await pump(tester, const PasswordManagerToolSetup(kind: PasswordManagerKind.keePassXc));
    expect(find.text(l10n.pmSetupNoDatabase), findsOneWidget);
    picker.path = r'D:\vault\team.kdbx';
    await tap(tester, 'pm-setup-kpx-choose');
    expect(container.read(passwordManagerSettingsProvider).keePassXc?.path, r'D:\vault\team.kdbx');
    expect(find.text(l10n.pmSetupNoDatabase), findsNothing);
  });

  testWidgets('Settings uses the same piece: where each is, or what to do', (tester) async {
    files.add(_winget);
    await pump(tester, const PasswordManagerSettingsPanel());
    expect(find.text(l10n.pmToolFound('op', _winget)), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-setup-bw')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-setup-kpx')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-settings-set-op')), findsOneWidget, reason: 'a found tool can be changed');
  });

  testWidgets('connecting with the tool missing: set up in the same question, the password typed this once',
      (tester) async {
    await pump(
        tester,
        Builder(
            builder: (context) => TextButton(
                onPressed: () => showPasswordManagerTypeOnce(context, PasswordManagerKind.onePassword, 'ops@web-01:22',
                    failure: PmFailure.notInstalled),
                child: const Text('ask'))));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmSetupTypeOnceMissing('op')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-setup-in-type-once')), findsOneWidget);
    expect(find.text(l10n.pmFailNotInstalled('op')), findsNothing, reason: 'it pointed to Settings');
    expect(find.byKey(const ValueKey('pm-type-field')), findsOneWidget);
  });
}
