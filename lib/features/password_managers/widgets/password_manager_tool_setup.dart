import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

// A password manager's command line tool set up where it is needed (quick,
// in place): where the key editor,
// adding from a password manager or moving a password asks for the tool,
// and in Settings. Found, it says where in one quiet line. Not found, it
// says so with what to do right there: look again, choose the file, or
// install it the tool's own way (the command to copy, the official page)
// and the one step after (1Password's app setting, Bitwarden's first
// sign-in). What is chosen is kept in the same per-device setting Settings
// uses, after the same check as a tool found (an absolute path, an .exe on
// Windows).

/// The official install of [kind]'s tool on [platform] ('windows', 'macos'
/// or 'linux'): a command to copy (null where the page is the way), and the
/// page that tells the rest.
({String? command, String page}) passwordManagerInstall(PasswordManagerKind kind, String platform) => switch (kind) {
      PasswordManagerKind.onePassword => (
          command: switch (platform) {
            'windows' => 'winget install AgileBits.1Password.CLI',
            'macos' => 'brew install 1password-cli',
            _ => null,
          },
          page: 'https://developer.1password.com/docs/cli/get-started/',
        ),
      PasswordManagerKind.bitwarden => (
          command: switch (platform) {
            'windows' => 'choco install bitwarden-cli',
            'macos' => 'npm install -g @bitwarden/cli',
            _ => 'sudo snap install bw',
          },
          page: 'https://bitwarden.com/help/cli/',
        ),
      PasswordManagerKind.keePassXc => (
          command: switch (platform) {
            'windows' => 'winget install -e --id KeePassXCTeam.KeePassXC',
            'macos' => 'brew install --cask keepassxc',
            _ => 'sudo snap install keepassxc',
          },
          page: 'https://keepassxc.org/download/',
        ),
    };

/// [kind]'s tool: where it is, or how to set it up, in place.
///
/// [manage] (Settings) keeps a found tool's Choose and, where a path was
/// set, Find it, to change it. [withDatabase] asks for KeePassXC's database
/// right here when the tool is found and none is set.
class PasswordManagerToolSetup extends ConsumerStatefulWidget {
  const PasswordManagerToolSetup(
      {super.key, required this.kind, this.manage = false, this.withDatabase = true, this.onChanged});

  final PasswordManagerKind kind;
  final bool manage;
  final bool withDatabase;

  /// After a look again or a file chosen: the place around it may show what
  /// needs the tool now.
  final VoidCallback? onChanged;

  @override
  ConsumerState<PasswordManagerToolSetup> createState() => _PasswordManagerToolSetupState();
}

class _PasswordManagerToolSetupState extends ConsumerState<PasswordManagerToolSetup> {
  /// Looked again and still nothing: said, so the button did something.
  bool _stillMissing = false;

  /// A file chosen that cannot be run: said, and not kept.
  String? _refused;

  @override
  void didUpdateWidget(covariant PasswordManagerToolSetup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _stillMissing = false;
      _refused = null;
    }
  }

  Future<String?> _pick(String title, {List<String>? extensions}) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
      withData: false,
    );
    return picked?.files.single.path;
  }

  /// Looks again: a path set before that does not run is let go of first,
  /// so the usual places are looked in.
  Future<void> _findAgain(PasswordManagers managers) async {
    final set = ref.read(passwordManagerSettingsProvider).paths[widget.kind];
    if (set != null && !managers.runnable(set)) {
      await ref.read(passwordManagerSettingsProvider.notifier).setToolPath(widget.kind, null);
    }
    if (!mounted) return;
    setState(() {
      _refused = null;
      _stillMissing = managers.toolPath(widget.kind) == null;
    });
    widget.onChanged?.call();
  }

  /// The person shows where the tool is: kept when it would run.
  Future<void> _choose(PasswordManagers managers) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(l10n.pmSettingsWhereIs(passwordManagerTool(widget.kind)));
    if (picked == null || !mounted) return;
    if (!managers.runnable(picked)) {
      setState(() => _refused = picked);
      return;
    }
    await ref.read(passwordManagerSettingsProvider.notifier).setToolPath(widget.kind, picked.trim());
    if (mounted) {
      setState(() {
        _refused = null;
        _stillMissing = false;
      });
      widget.onChanged?.call();
    }
  }

  Future<void> _chooseDatabase() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(l10n.pmSettingsChooseDatabase, extensions: const ['kdbx']);
    if (picked == null || !mounted) return;
    final kpx = ref.read(passwordManagerSettingsProvider).keePassXc;
    await ref
        .read(passwordManagerSettingsProvider.notifier)
        .setKeePassXc(KeePassXcDatabase(path: picked, keyFile: kpx?.keyFile, noPassword: kpx?.noPassword ?? false));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final managers = ref.watch(passwordManagersProvider);
    if (managers == null) return const SizedBox.shrink();
    final settings = ref.watch(passwordManagerSettingsProvider);
    final kind = widget.kind;
    final tool = passwordManagerTool(kind);
    final path = managers.toolPath(kind);
    final quiet = TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textTertiary);
    final code = kind.code;

    if (path != null) {
      final noDatabase =
          widget.withDatabase && kind == PasswordManagerKind.keePassXc && settings.keePassXc == null;
      return Column(
        key: ValueKey('pm-setup-found-$code'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.checkCircle2, size: 13, color: ZestTokens.statusHealthy),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.pmToolFound(tool, path),
                  key: const ValueKey('pm-tool'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: quiet,
                ),
              ),
              if (widget.manage) ...[
                const SizedBox(width: 8),
                ZestButton(
                  key: ValueKey('pm-settings-set-$code'),
                  label: l10n.pmSettingsChoose,
                  variant: ZestButtonVariant.ghost,
                  onPressed: () => unawaited(_choose(managers)),
                ),
                if (settings.paths[kind] != null)
                  ZestButton(
                    key: ValueKey('pm-settings-reset-$code'),
                    label: l10n.pmSettingsLookAgain,
                    variant: ZestButtonVariant.ghost,
                    onPressed: () async {
                      await ref.read(passwordManagerSettingsProvider.notifier).setToolPath(kind, null);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ],
          ),
          if (_refused case final refused?) ...[
            const SizedBox(height: 6),
            _refusedLine(l10n, managers, refused),
          ],
          if (noDatabase) ...[
            const SizedBox(height: 8),
            Row(
              key: const ValueKey('pm-setup-kpx-db'),
              children: [
                Icon(LucideIcons.alertTriangle, size: 13, color: ZestTokens.statusWarning),
                const SizedBox(width: 6),
                Expanded(child: Text(l10n.pmSetupNoDatabase, style: quiet.copyWith(color: ZestTokens.textSecondary))),
                const SizedBox(width: 8),
                ZestButton(
                  key: const ValueKey('pm-setup-kpx-choose'),
                  label: l10n.pmSetupChooseDatabase,
                  icon: LucideIcons.database,
                  onPressed: () => unawaited(_chooseDatabase()),
                ),
              ],
            ),
          ],
        ],
      );
    }

    final install = passwordManagerInstall(kind, managers.platform);
    final set = settings.paths[kind];
    final name = passwordManagerName(kind);
    final after = switch (kind) {
      PasswordManagerKind.onePassword => l10n.pmSetupAfterOnePassword,
      PasswordManagerKind.bitwarden => l10n.pmSetupAfterBitwarden,
      PasswordManagerKind.keePassXc => l10n.pmSetupAfterKeePassXc,
    };
    return Container(
      key: ValueKey('pm-setup-$code'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.alertTriangle, size: 14, color: ZestTokens.statusWarning),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  set == null ? l10n.pmSetupMissing(tool, name) : l10n.pmSettingsNotRunnable(set),
                  key: const ValueKey('pm-tool'),
                  style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(l10n.pmSetupInstallIt, style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (install.command case final command?) _CommandChip(command: command),
              ZestButton(
                key: ValueKey('pm-setup-page-$code'),
                label: l10n.pmSetupOfficialPage,
                variant: ZestButtonVariant.ghost,
                trailingIcon: LucideIcons.externalLink,
                onPressed: () =>
                    unawaited(launchUrl(Uri.parse(install.page), mode: LaunchMode.externalApplication)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(after, key: ValueKey('pm-setup-after-$code'), style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ZestButton(
                key: ValueKey('pm-setup-find-$code'),
                label: l10n.pmSetupCheckAgain,
                icon: LucideIcons.refreshCw,
                onPressed: () => unawaited(_findAgain(managers)),
              ),
              ZestButton(
                key: ValueKey('pm-setup-choose-$code'),
                label: l10n.pmSetupChooseFile(managers.toolFileName(kind)),
                icon: LucideIcons.folderOpen,
                variant: ZestButtonVariant.ghost,
                onPressed: () => unawaited(_choose(managers)),
              ),
              if (_stillMissing && _refused == null)
                Text(l10n.pmSetupStillMissing(tool),
                    key: ValueKey('pm-setup-still-$code'), style: quiet),
            ],
          ),
          if (_refused case final refused?) ...[
            const SizedBox(height: 6),
            _refusedLine(l10n, managers, refused),
          ],
        ],
      ),
    );
  }

  Widget _refusedLine(AppLocalizations l10n, PasswordManagers managers, String refused) => Text(
        l10n.pmSetupChosenNotRunnable(managers.toolFileName(widget.kind)),
        key: ValueKey('pm-setup-refused-${widget.kind.code}'),
        style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusCritical),
      );
}

/// The install command, in the terminal's letters, with a Copy button.
class _CommandChip extends StatelessWidget {
  const _CommandChip({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SelectableText(
              command,
              key: const ValueKey('pm-setup-command'),
              maxLines: 1,
              style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textPrimary),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('pm-setup-copy'),
            tooltip: l10n.copy,
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: Icon(LucideIcons.copy, color: ZestTokens.textSecondary),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (context.mounted) showTopSnackBar(context, l10n.pmSetupCopied, isSuccess: true);
            },
          ),
        ],
      ),
    );
  }
}
