import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show decodeCsvBytes, kCsvMaxBytes, kCsvMaxHosts;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart' show ImportCompatibilityOption;
import 'package:zestssh/features/onboarding/data/lan_scan_service.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

// The desktop "get connected" flows (Import from SSH config, Scan the local
// network) as modals on the shared dialog shell, instead of the pushed mobile
// screens: the same chrome as every other desktop dialog, the primary action
// in the footer, and the config file read for you when it is where it always
// is. Both resolve with what they did so the caller can toast the outcome.

/// Import from SSH config. Resolves with the import outcome, or null when
/// nothing was imported (cancelled, no hosts).
/// [pickFile]: straight to choosing a file (a guide sent the person here
/// with a file to choose, termius-export's). [file]: that file, chosen under
/// Import a file.
Future<SshImportOutcome?> showDesktopSshConfigImport(BuildContext context, {bool pickFile = false, ImportFile? file}) {
  return showZestModal<SshImportOutcome>(
    context: context,
    size: ZestModalSize.standard,
    child: _SshConfigImportDialog(pickFile: pickFile, file: file),
  );
}

/// Scan the local network for SSH servers. Resolves with the number of
/// connections added (plus how many the tier limit refused), or null.
Future<({int added, int failedLimit})?> showDesktopLanScan(
    BuildContext context) {
  return showZestModal<({int added, int failedLimit})>(
    context: context,
    size: ZestModalSize.standard,
    child: const _LanScanDialog(),
  );
}

/// Toast the outcome of [showDesktopSshConfigImport] / [showDesktopLanScan].
void toastImportOutcome(BuildContext context,
    {required int added, required int failedLimit}) {
  final l10n = AppLocalizations.of(context)!;
  if (added > 0) {
    showTopSnackBar(context, l10n.sshImportImportedCount(added),
        isSuccess: true);
  } else if (failedLimit > 0) {
    showTopSnackBar(context, l10n.sshImportSomeFailed(failedLimit),
        isError: true);
  }
}

// ── Import from SSH config ──────────────────────────────────────────────────

enum _ImportStage { detecting, input, review }

class _SshConfigImportDialog extends ConsumerStatefulWidget {
  const _SshConfigImportDialog({this.pickFile = false, this.file});

  final bool pickFile;
  final ImportFile? file;

  @override
  ConsumerState<_SshConfigImportDialog> createState() =>
      _SshConfigImportDialogState();
}

class _SshConfigImportDialogState extends ConsumerState<_SshConfigImportDialog> {
  final _source = const SshConfigSource();
  final _text = TextEditingController();
  _ImportStage _stage = _ImportStage.detecting;
  SshConfigScanResult? _result;
  String? _sourcePath;
  final Set<int> _selected = {};
  String? _error;

  /// The failure behind [_error] where one did ([_error] is then its
  /// sentence), for Copy details.
  ({String said, Object cause})? _failure;
  bool _importing = false;

  /// How many private keys its hosts name by IdentityFile can be read on this
  /// computer; and whether they go in with the hosts: only when the person
  /// ticks it (a private key is never copied unasked, and read only to go in).
  int _keyCount = 0;
  bool _importKeys = false;

  /// Compatibility mode for every host imported (off unless ticked).
  bool _compatibility = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    final file = widget.file;
    if (file != null) {
      _stage = _ImportStage.input;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _takeFile(file);
      });
    } else if (widget.pickFile) {
      _stage = _ImportStage.input;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickFile();
      });
    } else {
      _detect();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Read ~/.ssh/config straight away: on a desktop that is where the file
  /// lives, so most users never see the input step.
  Future<void> _detect() async {
    final found = await _source.detect();
    if (!mounted) return;
    if (found != null && (found.entries.isNotEmpty || found.skipped.isNotEmpty)) {
      _showResult(found, path: _source.configPath());
    } else {
      setState(() => _stage = _ImportStage.input);
    }
  }

  void _showResult(SshConfigScanResult result, {String? path}) {
    setState(() {
      _result = result;
      _sourcePath = path;
      _selected
        ..clear()
        ..addAll(List.generate(result.entries.length, (i) => i));
      _error = null;
      _stage = _ImportStage.review;
      _keyCount = 0;
    });
    // The keys its hosts use, where this computer has them: how many.
    readIdentityKeys(result.entries, configPath: path).then((keys) {
      if (mounted && identical(_result, result)) setState(() => _keyCount = keys.length);
    });
  }

  Future<void> _pickFile() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        initialDirectory: defaultSshPickerDirectory(),
      );
      final path = picked?.files.firstOrNull?.path;
      if (path == null) return;
      final file = await readImportFile(path, rdp: ref.read(rdpOfferedProvider));
      if (!mounted) return;
      // A file for another import is said so, and goes there: nothing of it
      // is read here.
      if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig}, readsHere: true)) {
        return;
      }
      final read = await importFileToRead(file);
      if (mounted) await _takeFile(read);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ImportStage.input;
          _error = l10n.sshImportFileNotRead;
          _failure = (said: _error!, cause: e);
        });
      }
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
        _stage = _ImportStage.input;
        _error = bytes != null && bytes.length > kCsvMaxBytes
            ? l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024))
            : l10n.sshImportFileNotRead;
        _failure = null;
      });
      return;
    }
    if (bytes.length <= kImportHereBytes) {
      _text.text = decodeCsvBytes(bytes);
      _parse(path: file.path);
      return;
    }
    try {
      final result = await parseSshConfigAway(bytes);
      if (mounted) _showResult(result, path: file.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ImportStage.input;
          _error = l10n.sshImportNotSshConfig;
          _failure = (said: _error!, cause: e);
        });
      }
    }
  }

  Future<void> _paste() async {
    final l10n = AppLocalizations.of(context)!;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    final text = data!.text!;
    // What it is first, whatever its size: a private key is never put in the
    // field, in the clear, to be looked at later.
    final file = await importFileAway(name: l10n.csvImpPasted, bytes: utf8.encode(text), rdp: ref.read(rdpOfferedProvider));
    if (!mounted) return;
    if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig})) return;
    if (!mounted) return;
    if (text.length <= kImportHereBytes) {
      _text.text = text;
    } else {
      // Too much to lay out in a field: read as a file chosen is.
      await _takeFile(file);
    }
  }

  /// What was typed or pasted: what belongs elsewhere is said so, and does not
  /// stay in the field (a private key above all).
  Future<void> _parseTyped() async {
    final l10n = AppLocalizations.of(context)!;
    final file = await importFileAway(
      name: l10n.csvImpPasted,
      bytes: utf8.encode(_text.text.trim()),
      rdp: ref.read(rdpOfferedProvider),
    );
    if (!mounted) return;
    if (await routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig})) {
      if (mounted) _text.clear();
      return;
    }
    if (mounted) await _takeFile(file);
  }

  void _parse({String? path}) {
    final l10n = AppLocalizations.of(context)!;
    final content = _text.text.trim();
    if (content.isEmpty) {
      setState(() => _error = l10n.sshImportEmptyContent);
      return;
    }
    try {
      _showResult(_source.parse(content), path: path);
    } catch (e) {
      setState(() {
        _error = l10n.sshImportNotSshConfig;
        _failure = (said: _error!, cause: e);
      });
    }
  }

  Future<void> _import() async {
    final result = _result;
    if (result == null || _selected.isEmpty || _importing) return;
    setState(() => _importing = true);
    final entries = [for (final i in _selected) result.entries[i]];
    final l10n = AppLocalizations.of(context)!;
    final keys = _importKeys ? await readIdentityKeys(result.entries, configPath: _sourcePath) : const <String, String>{};
    if (!mounted) return;
    final outcome = await importSshEntries(ref, entries, l10n: l10n, keys: keys, compatibilityMode: _compatibility);
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final result = _result;
    switch (_stage) {
      case _ImportStage.detecting:
        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.download,
          title: l10n.firstRunImportTitle,
          subtitle: l10n.sshImportDetecting,
          body: const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          secondaryAction: (
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(),
          ),
        );
      case _ImportStage.input:
        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.download,
          title: l10n.firstRunImportTitle,
          subtitle: l10n.firstRunImportDescEmpty,
          body: _inputBody(l10n),
          primaryAction: (
            label: l10n.sshImportParseConfig,
            icon: LucideIcons.search,
            onPressed: _text.text.trim().isEmpty ? null : _parseTyped,
          ),
          secondaryAction: (
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(),
          ),
        );
      case _ImportStage.review:
        final entries = result?.entries ?? const <OnboardingSshEntry>[];
        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.download,
          title: l10n.firstRunImportTitle,
          subtitle: _sourcePath != null
              ? l10n.sshImportFoundIn(_sourcePath!)
              : l10n.sshImportDesc,
          body: _reviewBody(l10n, result!),
          primaryAction: (
            label: l10n.sshImportButtonCount(_selected.length),
            icon: LucideIcons.check,
            onPressed:
                entries.isEmpty || _selected.isEmpty || _importing ? null : _import,
          ),
          secondaryAction: (
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(),
          ),
          tertiaryAction: (
            label: l10n.sshImportChooseAnother,
            onPressed: () => setState(() {
              _stage = _ImportStage.input;
              _error = null;
            }),
          ),
        );
    }
  }

  Widget _inputBody(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.sshImportDesc,
          style: TextStyle(
              fontSize: 12.5, height: 1.5, color: ZestTokens.textSecondary),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            ZestButton(
              label: l10n.sshImportChooseFile,
              icon: LucideIcons.folderOpen,
              variant: ZestButtonVariant.secondary,
              onPressed: _pickFile,
            ),
            const SizedBox(width: ZestSizing.buttonGap),
            ZestButton(
              label: l10n.sshImportPasteFromClipboard,
              icon: LucideIcons.clipboard,
              variant: ZestButtonVariant.ghost,
              onPressed: _paste,
            ),
          ],
        ),
        const SizedBox(height: 14),
        ZestField(
          label: l10n.sshImportFieldLabel,
          controller: _text,
          isMono: true,
          maxLines: 10,
          placeholder:
              'Host myserver\n  HostName 192.168.1.100\n  User admin\n  Port 22',
          errorText: _error,
        ),
        if (_failure case (:final said, :final cause) when said == _error)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: CopyDetailsButton(detail: ErrorReport.build(what: said, where: 'Importing an SSH config', error: cause)),
          ),
      ],
    );
  }

  Widget _reviewBody(AppLocalizations l10n, SshConfigScanResult result) {
    final entries = result.entries;
    final skipped = result.skipped;
    final allSelected = entries.isNotEmpty && _selected.length == entries.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.sshImportReviewNoneImportable,
              style: TextStyle(
                  fontSize: 13, color: ZestTokens.textSecondary),
            ),
          )
        else ...[
          ZestSectionHeader(
            label: l10n.sshImportHostsFound(entries.length),
            actionLabel: allSelected
                ? l10n.sshImportDeselectAll
                : l10n.sshImportSelectAll,
            onAction: () => setState(() {
              if (allSelected) {
                _selected.clear();
              } else {
                _selected.addAll(List.generate(entries.length, (i) => i));
              }
            }),
          ),
          // The keys these hosts use, found where their config says: offered,
          // to be saved encrypted with the hosts' identities.
          if (_keyCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                key: const ValueKey('ssh-import-keys'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _importKeys = !_importKeys),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: ZestTokens.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ZestTokens.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Checkbox(value: _importKeys, onChanged: (v) => setState(() => _importKeys = v ?? false)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.sshImportKeysOffer(_keyCount),
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                            const SizedBox(height: 2),
                            Text(l10n.sshImportKeysOfferSub,
                                style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (result.cut)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(l10n.csvImpCut(kCsvMaxHosts),
                  key: const ValueKey('ssh-import-cut'), style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
            ),
          // A config may hold thousands: only the rows on screen are built.
          SizedBox(
            height: (entries.length * 56.0).clamp(56.0, 360.0),
            child: ListView.builder(
              key: const ValueKey('ssh-import-rows'),
              itemCount: entries.length,
              itemBuilder: (context, i) => _PickRow(
                selected: _selected.contains(i),
                onChanged: (v) => setState(() {
                  if (v) {
                    _selected.add(i);
                  } else {
                    _selected.remove(i);
                  }
                }),
                title: RedactedText(
                  Redactable.host(entries[i].alias),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ZestTokens.textPrimary),
                ),
                subtitle: _entrySubtitle(entries[i]),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ImportCompatibilityOption(
            key: const ValueKey('ssh-import-compatibility'),
            value: _compatibility,
            onChanged: _importing ? null : (v) => setState(() => _compatibility = v),
          ),
        ],
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 16),
          ZestSectionHeader(
            label: l10n.sshImportReviewSkipped(skipped.length),
          ),
          SizedBox(
            height: (skipped.length * 26.0).clamp(26.0, 200.0),
            child: ListView.builder(
              key: const ValueKey('ssh-import-skipped'),
              itemCount: skipped.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  children: [
                    Icon(LucideIcons.minusCircle,
                        size: 13, color: ZestTokens.textTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: RedactedText(
                        Redactable.host(skipped[i].label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'JetBrainsMono',
                            color: ZestTokens.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      switch (skipped[i].reason) {
                        SshSkipReason.wildcard => l10n.sshImportSkipReasonWildcard,
                        SshSkipReason.host => l10n.sshImportSkipReasonHost,
                        SshSkipReason.port => l10n.sshImportSkipReasonPort,
                      },
                      style: TextStyle(
                          fontSize: 11.5, color: ZestTokens.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// `user@host:port`, plus the jump host, composed from masked parts so
  /// recording mode never leaks an address.
  Widget _entrySubtitle(OnboardingSshEntry e) {
    final user = e.user;
    final jump = e.proxyJumpHost;
    return Consumer(
      builder: (context, ref, _) => Text(
        '${user != null ? '${Redactable.username(user).displayIn(ref)}@' : ''}'
        '${Redactable.address('${e.hostname}:${e.port}').displayIn(ref)}'
        '${jump != null ? '  via ${Redactable.address(jump).displayIn(ref)}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 11.5,
            color: ZestTokens.textTertiary),
      ),
    );
  }
}

// ── Scan the local network ──────────────────────────────────────────────────

enum _ScanPhase { resolving, ready, scanning, done, unavailable }

class _LanScanDialog extends ConsumerStatefulWidget {
  const _LanScanDialog();

  @override
  ConsumerState<_LanScanDialog> createState() => _LanScanDialogState();
}

class _LanScanDialogState extends ConsumerState<_LanScanDialog> {
  final _service = LanScanService();
  _ScanPhase _phase = _ScanPhase.resolving;
  LanScanScope? _scope;
  final List<LanScanHit> _hits = [];
  final Set<String> _selected = {};
  int _scanned = 0;
  int _total = 0;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _service.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    final scope = await _service.resolveScope();
    if (!mounted) return;
    setState(() {
      _scope = scope;
      _phase = scope == null ? _ScanPhase.unavailable : _ScanPhase.ready;
    });
  }

  Future<void> _start() async {
    final scope = _scope;
    if (scope == null) return;
    setState(() {
      _phase = _ScanPhase.scanning;
      _hits.clear();
      _selected.clear();
      _scanned = 0;
      _total = scope.hostCount;
    });
    await _service.scan(
      scope: scope,
      onHit: (hit) {
        if (!mounted) return;
        setState(() {
          _hits.add(hit);
          _selected.add(hit.host);
        });
      },
      onProgress: (scanned, total) {
        if (!mounted) return;
        setState(() {
          _scanned = scanned;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _phase = _ScanPhase.done);
  }

  void _stop() {
    _service.cancel();
    setState(() => _phase = _ScanPhase.done);
  }

  Future<void> _add() async {
    if (_selected.isEmpty || _adding) return;
    setState(() => _adding = true);
    final outcome = await addLanScanHits(ref, _selected);
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scope = _scope;
    final done = _phase == _ScanPhase.done;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.radar,
      title: l10n.firstRunScanTitle,
      subtitle: scope == null
          ? null
          : l10n.networkScanScope(scope.cidr),
      body: _body(l10n),
      primaryAction: switch (_phase) {
        _ScanPhase.ready => (
            label: l10n.networkScanStart,
            icon: LucideIcons.radar,
            onPressed: _start,
          ),
        _ScanPhase.scanning => (
            label: l10n.networkScanStop,
            icon: LucideIcons.square,
            onPressed: _stop,
          ),
        _ScanPhase.done => (
            label: l10n.networkScanAddSelected(_selected.length),
            icon: LucideIcons.plus,
            onPressed: _selected.isEmpty || _adding ? null : _add,
          ),
        _ => null,
      },
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => Navigator.of(context).pop(),
      ),
      tertiaryAction: done
          ? (label: l10n.networkScanRescan, onPressed: _start)
          : null,
    );
  }

  Widget _body(AppLocalizations l10n) {
    switch (_phase) {
      case _ScanPhase.resolving:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      case _ScanPhase.unavailable:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Row(
            children: [
              Icon(LucideIcons.wifiOff,
                  size: 18, color: ZestTokens.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.networkScanUnavailable,
                  style: TextStyle(
                      fontSize: 13, height: 1.5, color: ZestTokens.textSecondary),
                ),
              ),
            ],
          ),
        );
      case _ScanPhase.ready:
        return Text(
          l10n.networkScanExplainAction,
          style: TextStyle(
              fontSize: 12.5, height: 1.5, color: ZestTokens.textSecondary),
        );
      case _ScanPhase.scanning:
      case _ScanPhase.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_phase == _ScanPhase.scanning) ...[
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        value: _total == 0 ? null : _scanned / _total,
                        backgroundColor: ZestTokens.surfaceRaised,
                        color: ZestTokens.brand,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.networkScanProgress(_scanned, _total),
                    style: TextStyle(
                        fontSize: 12, color: ZestTokens.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            ZestSectionHeader(label: l10n.networkScanFound(_hits.length)),
            if (_hits.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _phase == _ScanPhase.done
                      ? l10n.networkScanEmpty
                      : l10n.networkScanWaiting,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                      color: ZestTokens.textTertiary),
                ),
              )
            else
              for (final hit in _hits)
                _PickRow(
                  selected: _selected.contains(hit.host),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _selected.add(hit.host);
                    } else {
                      _selected.remove(hit.host);
                    }
                  }),
                  title: RedactedText(
                    Redactable.address(hit.host),
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: ZestTokens.textPrimary),
                  ),
                  subtitle: Text(
                    '${latencyText(hit.latencyMs)} ms  ·  port 22',
                    style: TextStyle(
                        fontSize: 11.5, color: ZestTokens.textTertiary),
                  ),
                ),
          ],
        );
    }
  }
}

/// Create a connection for every selected scan hit, honouring the tier
/// limit the same way the mobile scan view does.
Future<({int added, int failedLimit})> addLanScanHits(
    WidgetRef ref, Iterable<String> hosts) async {
  final crud = ref.read(connectionCrudProvider);
  var added = 0;
  var failedLimit = 0;
  var limitHit = false;
  for (final host in hosts) {
    if (limitHit) {
      failedLimit++;
      continue;
    }
    try {
      await crud.create(label: host, host: host, port: 22);
      added++;
    } on StateError {
      limitHit = true;
      failedLimit++;
    }
  }
  return (added: added, failedLimit: failedLimit);
}

// ── Shared row ──────────────────────────────────────────────────────────────

/// A selectable row for the review lists: brand checkbox, title over a mono
/// subtitle, raised on hover, the whole row a toggle target.
class _PickRow extends StatefulWidget {
  const _PickRow({
    required this.selected,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool selected;
  final ValueChanged<bool> onChanged;
  final Widget title;
  final Widget subtitle;

  @override
  State<_PickRow> createState() => _PickRowState();
}

class _PickRowState extends State<_PickRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onChanged(!widget.selected),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.06)
                : _hovering
                    ? ZestTokens.surfaceRaised
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.35)
                  : ZestTokens.borderSubtle,
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: widget.selected,
                  activeColor: ZestTokens.brand,
                  checkColor: const Color(0xFF1A0D04),
                  side: BorderSide(color: ZestTokens.borderStrong),
                  onChanged: (v) => widget.onChanged(v ?? false),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    widget.title,
                    const SizedBox(height: 2),
                    widget.subtitle,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
