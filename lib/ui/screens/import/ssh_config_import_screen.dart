import 'dart:convert';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show decodeCsvBytes, kCsvMaxBytes, kCsvMaxHosts;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart' show ImportCompatibilityOption;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// Screen for importing connections from an SSH config file.
class SshConfigImportScreen extends ConsumerStatefulWidget {
  const SshConfigImportScreen({super.key, this.pickFile = false, this.file});

  /// Straight to choosing a file (the Termius guide's Choose SSH config file).
  final bool pickFile;

  /// A file chosen already (Import a file).
  final ImportFile? file;

  @override
  ConsumerState<SshConfigImportScreen> createState() =>
      _SshConfigImportScreenState();
}

class _SshConfigImportScreenState
    extends ConsumerState<SshConfigImportScreen> {
  final _textController = TextEditingController();
  List<OnboardingSshEntry>? _entries;
  final Set<int> _selectedEntries = {};
  bool _isImporting = false;
  String? _error;

  /// The failure behind [_error] where one did ([_error] is then its
  /// sentence), for Copy details.
  ({String said, Object cause})? _failure;

  /// Compatibility mode for every host imported (off unless ticked).
  bool _compatibility = false;

  /// More hosts came than are read.
  bool _cut = false;

  @override
  void initState() {
    super.initState();
    final file = widget.file;
    if (file != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _takeFile(file);
      });
    } else if (widget.pickFile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickFile();
      });
    }
  }

  /// Reads [file] as a config; one that is no text is said to be unreadable,
  /// and one larger than a host file may be to be that. Much of it is read off
  /// the screen's thread, and never put in a field to lay out.
  Future<void> _takeFile(ImportFile file) async {
    final l10n = AppLocalizations.of(context)!;
    final bytes = file.bytes;
    if (bytes == null || bytes.length > kCsvMaxBytes || !importBytesAreText(bytes)) {
      setState(() {
        _error = bytes != null && bytes.length > kCsvMaxBytes
            ? l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024))
            : l10n.sshImportFileNotRead;
        _failure = null;
      });
      return;
    }
    if (bytes.length <= kImportHereBytes) {
      _textController.text = decodeCsvBytes(bytes);
      _parseConfig();
      return;
    }
    try {
      final result = await parseSshConfigAway(bytes);
      if (mounted) _showEntries(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = l10n.sshImportNotSshConfig;
          _failure = (said: _error!, cause: e);
        });
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ResponsiveScaffold(
      title: l10n.sshImportTitle,
      actions: [
        if (_entries != null && _selectedEntries.isNotEmpty)
          TextButton.icon(
            onPressed: _isImporting ? null : _importSelected,
            icon: _isImporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.checkCheck),
            label: Text(l10n.sshImportButtonCount(_selectedEntries.length)),
          ),
      ],
      body: _entries != null ? _buildEntryList() : _buildInputView(),
    );
  }

  Widget _buildInputView() {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Info banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.info,
                        size: 20,
                        color: AppColors.accentInk.withValues(alpha: 0.8)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.sshImportHeading,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.sshImportDesc,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // File picker
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(LucideIcons.fileText),
            label: Text(l10n.sshImportChooseFile),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentInk,
              side: BorderSide(color: AppColors.brandOrange),
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 16),

          // OR divider
          Row(
            children: [
              Expanded(
                child: Divider(
                    color: AppColors.divider.withValues(alpha: 0.5)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(l10n.sshImportOr,
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ),
              Expanded(
                child: Divider(
                    color: AppColors.divider.withValues(alpha: 0.5)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Text input
          TextField(
            controller: _textController,
            maxLines: 12,
            decoration: InputDecoration(
              hintText:
                  'Host myserver\n  HostName 192.168.1.100\n  User admin\n  Port 22',
              hintStyle: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                color: ZestTokens.textPlaceholder,
              ),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(12),
            ),
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),

          // Paste button
          TextButton.icon(
            onPressed: _pasteFromClipboard,
            icon: const Icon(LucideIcons.clipboardPaste, size: 18),
            label: Text(l10n.sshImportPasteFromClipboard),
          ),
          const SizedBox(height: 16),

          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_error!, style: TextStyle(color: AppColors.error, fontSize: 13)),
                  if (_failure case (:final said, :final cause) when said == _error)
                    CopyDetailsButton(detail: ErrorReport.build(what: said, where: 'Importing an SSH config', error: cause)),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Parse button
          FilledButton.icon(
            onPressed: _parseTyped,
            icon: const Icon(LucideIcons.search),
            label: Text(l10n.sshImportParseConfig),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryList() {
    if (_entries!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.searchX,
                size: 48,
                color: AppColors.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context)!.sshImportNoHostsFound),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() {
                _entries = null;
                _selectedEntries.clear();
              }),
              child: Text(AppLocalizations.of(context)!.sshImportTryAgain),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Text(
                AppLocalizations.of(context)!.sshImportHostsFound(_entries!.length),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_selectedEntries.length == _entries!.length) {
                      _selectedEntries.clear();
                    } else {
                      _selectedEntries.addAll(
                        List.generate(_entries!.length, (i) => i),
                      );
                    }
                  });
                },
                child: Text(
                  _selectedEntries.length == _entries!.length
                      ? AppLocalizations.of(context)!.sshImportDeselectAll
                      : AppLocalizations.of(context)!.sshImportSelectAll,
                ),
              ),
            ],
          ),
        ),

        if (_cut)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(AppLocalizations.of(context)!.csvImpCut(kCsvMaxHosts),
                key: const ValueKey('ssh-import-cut'), style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ImportCompatibilityOption(
            key: const ValueKey('ssh-import-compatibility'),
            value: _compatibility,
            onChanged: _isImporting ? null : (v) => setState(() => _compatibility = v),
          ),
        ),

        Expanded(
          child: ListView.builder(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: _entries!.length,
            itemBuilder: (context, index) {
              final entry = _entries![index];
              final isSelected = _selectedEntries.contains(index);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: isSelected
                    ? AppColors.brandOrange.withValues(alpha: 0.08)
                    : null,
                child: CheckboxListTile(
                  value: isSelected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedEntries.add(index);
                      } else {
                        _selectedEntries.remove(index);
                      }
                    });
                  },
                  activeColor: AppColors.brandOrange,
                  // Recording mode: the alias is a host label, the subtitle
                  // a `user@host:port` composed from typed parts.
                  title: RedactedText(
                    Redactable.host(entry.alias),
                    style:
                        const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Consumer(
                    builder: (context, ref, _) => Text(
                      '${entry.user != null ? "${Redactable.username(entry.user!).displayIn(ref)}@" : ""}'
                      '${Redactable.address('${entry.hostname}:${entry.port}').displayIn(ref)}',
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  secondary: Icon(LucideIcons.server,
                      color: AppColors.accentInk),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        // Open straight to ~/.ssh (desktop): that is where `config` lives.
        initialDirectory: defaultSshPickerDirectory(),
      );
      if (result?.files.isNotEmpty == true) {
        final picked = result!.files.first;
        if (picked.path != null) {
          final file = await readImportFile(picked.path!, rdp: ref.read(rdpOfferedProvider));
          if (!mounted) return;
          // A file for another import is said so, and goes there: nothing of
          // it is read here.
          final l10n = AppLocalizations.of(context)!;
          if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig}, readsHere: true)) {
            return;
          }
          final read = await importFileToRead(file);
          if (mounted) await _takeFile(read);
        }
      }
    } catch (e) {
      setState(() {
        _error = AppLocalizations.of(context)!.sshImportFileNotRead;
        _failure = (said: _error!, cause: e);
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null) return;
    // What it is first, whatever its size: a private key is never put in the
    // field, in the clear, to be looked at later.
    final l10n = AppLocalizations.of(context)!;
    final file = await importFileAway(name: l10n.csvImpPasted, bytes: utf8.encode(text), rdp: ref.read(rdpOfferedProvider));
    if (!mounted) return;
    if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig})) return;
    if (!mounted) return;
    if (text.length <= kImportHereBytes) {
      _textController.text = text;
    } else {
      // Too much to lay out in a field: read as a file chosen is.
      await _takeFile(file);
    }
  }

  /// What was typed or pasted: what belongs elsewhere is said so, and does not
  /// stay in the field (a private key above all).
  Future<void> _parseTyped() async {
    final l10n = AppLocalizations.of(context)!;
    final content = _textController.text.trim();
    if (content.isEmpty) return _parseConfig();
    final file = await importFileAway(name: l10n.csvImpPasted, bytes: utf8.encode(content), rdp: ref.read(rdpOfferedProvider));
    if (!mounted) return;
    if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig})) {
      if (mounted) _textController.clear();
      return;
    }
    if (mounted) await _takeFile(file);
  }

  void _parseConfig() {
    final content = _textController.text.trim();
    if (content.isEmpty) {
      setState(() => _error = AppLocalizations.of(context)!.sshImportEmptyContent);
      return;
    }

    try {
      // The reading a computer makes of it (one entry per alias, no
      // wildcards), so both make the same hosts.
      _showEntries(const SshConfigSource().parse(content));
    } catch (e) {
      setState(() {
        _error = AppLocalizations.of(context)!.sshImportNotSshConfig;
        _failure = (said: _error!, cause: e);
      });
    }
  }

  void _showEntries(SshConfigScanResult result) => setState(() {
        _entries = result.entries;
        _cut = result.cut;
        _selectedEntries.addAll(List.generate(result.entries.length, (i) => i));
        _error = null;
      });

  Future<void> _importSelected() async {
    if (_entries == null || _selectedEntries.isEmpty) return;

    final l10n = AppLocalizations.of(context)!;

    setState(() => _isImporting = true);

    try {
      // The import a computer's makes: ProxyJump to the host it names,
      // IdentityFile kept in the host's note, names cleaned.
      final outcome = await importSshEntries(ref, [for (final i in _selectedEntries) _entries![i]],
          l10n: l10n, compatibilityMode: _compatibility);

      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.sshImportImportedCount(outcome.imported),
          isSuccess: true,
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.sshImportFailed,
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }
}
