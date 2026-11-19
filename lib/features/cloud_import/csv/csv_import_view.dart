import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/cloud_import/cloud_import_writer.dart' show CloudImportOutcome;
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';

/// What a CSV import ended with: the file's name, and what was written.
class CsvImportResult {
  const CsvImportResult({required this.fileName, required this.outcome});

  final String fileName;
  final CsvImportOutcome outcome;

  /// As a cloud import's outcome is said (the file's name for its account).
  CloudImportOutcome get asCloudOutcome => CloudImportOutcome()
    ..added = outcome.added
    ..failures.addAll(outcome.failures);
}

/// A file chosen: its name and what it holds.
typedef CsvPicked = ({String name, List<int> bytes});

/// Opens "Import hosts from a CSV file" (3.0), or from another app's file
/// ([kind], MobaXterm, SecureCRT or PuTTY's .reg): a file chosen, or text
/// pasted, its hosts read and shown with what an import does with each and
/// where they go, and Import. With [picked], that file, chosen already.
Future<CsvImportResult?> showCsvImport(BuildContext context, {HostFileKind kind = HostFileKind.csv, CsvPicked? picked}) =>
    showZestModal<CsvImportResult>(
      context: context,
      size: ZestModalSize.large,
      barrierDismissible: false,
      child: CsvImportDialog(kind: kind, picked: picked),
    );

/// The name of the app whose file [kind] is; null for a CSV file.
String? hostFileApp(HostFileKind kind) => switch (kind) {
      HostFileKind.csv || HostFileKind.paste => null,
      HostFileKind.mobaxterm => 'MobaXterm',
      HostFileKind.securecrt => 'SecureCRT',
      HostFileKind.putty => 'PuTTY',
      HostFileKind.filezilla => 'FileZilla',
      HostFileKind.winscp => 'WinSCP',
      HostFileKind.mremoteng => 'mRemoteNG',
      HostFileKind.remmina => 'Remmina',
      // (A Remote Desktop file has a name in each language: [hostFileAppIn].)
      HostFileKind.rdpfile => null,
    };

/// [hostFileApp], with the kinds whose name is said in the person's language.
String? hostFileAppIn(HostFileKind kind, AppLocalizations l10n) =>
    kind == HostFileKind.rdpfile ? l10n.migrateRdpFileTitle : hostFileApp(kind);

class CsvImportDialog extends ConsumerStatefulWidget {
  const CsvImportDialog({super.key, this.pickFile, this.pickedPath, this.picked, this.kind = HostFileKind.csv});

  /// A stand-in for tests: the file chosen; null when none was. [pickedPath]
  /// is where it stands to be.
  final Future<CsvPicked?> Function()? pickFile;
  final String? pickedPath;

  /// A file chosen before this opened (Import a file).
  final CsvPicked? picked;

  /// Where the file comes from: its title and its help say so. Whatever is
  /// chosen is read as what it is.
  final HostFileKind kind;

  @override
  ConsumerState<CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends ConsumerState<CsvImportDialog> {
  CsvHostFile? _file;
  String _fileName = '';

  /// Why the file chosen could not be read, and its details to copy.
  String? _problem;
  String? _problemDetail;

  CsvPlace? _place;
  var _statuses = const <CsvRowStatus>[];
  final _ticked = <int>{};

  /// What the person ticked or unticked themselves, by line: kept when the
  /// statuses are worked out again for another destination.
  final _chosen = <int, bool>{};

  /// The lines of the file whose hosts may be sent the password their key holds,
  /// ticked by the person, each for itself.
  final _passwordsAllowed = <int>{};

  var _destinations = const <ImportDestination>[ImportDestination.tree()];
  ImportDestination _destination = const ImportDestination.tree();
  var _busy = false;

  /// Hosts are being written: nothing closes it, nor goes back.
  var _importing = false;

  /// Compatibility mode for every host imported (off unless ticked).
  var _compatibility = false;

  /// The list typed or pasted (Paste a list).
  final _pasted = TextEditingController();

  /// What the file chosen turned out to be; null before one is read.
  HostFileKind? _readAs;

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _readPasted() async {
    if (_busy || _pasted.text.trim().isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      // What it is first, as for a file: a private key above all is no list,
      // and nothing of it stays or is shown.
      final file = await importFileAway(name: l10n.importPasteTitle, bytes: utf8.encode(_pasted.text), rdp: ref.read(rdpOfferedProvider));
      if (!mounted) return;
      if (!file.kind.isHostFile && file.kind != ImportKind.unknown) _pasted.clear();
      await _take(file);
    } catch (e) {
      if (mounted) _fail(l10n.csvImpUnreadable, '$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadDestinations();
    final picked = widget.picked;
    if (picked != null) {
      _busy = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _read(picked);
      });
    }
  }

  Future<void> _loadDestinations() async {
    final out = await importDestinations(ref);
    if (mounted) setState(() => _destinations = out);
  }

  void _fail(String problem, [String? detail]) => setState(() {
        _problem = problem;
        _problemDetail = detail;
        _busy = false;
        _importing = false;
      });

  Future<void> _read(CsvPicked picked) async {
    final l10n = AppLocalizations.of(context)!;
    final mb = kCsvMaxBytes ~/ (1024 * 1024);
    if (picked.bytes.length > kCsvMaxBytes) return _fail(l10n.csvImpTooLarge(mb));
    // Another app's RDP entries come in only where this build offers RDP hosts.
    final read = await readHostBytesAway(
      picked.bytes,
      pasted: widget.kind == HostFileKind.paste,
      rdp: ref.read(rdpOfferedProvider),
      name: picked.name,
    );
    if (!mounted) return;
    final file = read.file;
    final app = hostFileAppIn(widget.kind, l10n);
    _readAs = read.kind;
    // Another app's file asked for, and this is not one: say so in its words.
    if (app != null && file.problem != null && read.kind == HostFileKind.csv) {
      return _fail(l10n.migrateNotThisApp(app));
    }
    // A Remote Desktop file that names no computer: said in its own words.
    if (read.kind == HostFileKind.rdpfile &&
        file.problem == null &&
        file.rows.every((r) => r.problem == CsvRowProblem.noHost)) {
      return _fail(l10n.rdpFileNoAddress);
    }
    switch (file.problem) {
      case CsvFileProblem.empty:
        if (widget.kind == HostFileKind.paste) return _fail(l10n.pasteListEmpty);
        return _fail(app == null ? l10n.csvImpEmpty : l10n.migrateNotThisApp(app));
      case CsvFileProblem.noHostColumn:
        return _fail(l10n.csvImpNoHostColumn, file.ignored.isEmpty ? null : l10n.csvImpIgnored(file.ignored.join(', ')));
      case CsvFileProblem.tooLarge:
        return _fail(l10n.csvImpTooLarge(mb));
      case null:
        _fileName = picked.name;
        _chosen.clear();
        await _plan(file);
    }
  }

  /// What an import does with each host of [file] in the destination chosen;
  /// false where what is there could not be read.
  Future<bool> _plan(CsvHostFile file) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final db = await importDatabaseOf(ref, _destination);
      if (db == null) throw StateError('no database for ${_destination.key}');
      final place = await CsvPlace.of(db, crateId: _destination.crateId);
      final seen = <String>{};
      final statuses = [
        for (final r in file.rows) csvRowStatus(r, place.addresses, seen),
      ];
      if (!mounted) return false;
      setState(() {
        _file = file;
        _place = place;
        _problem = null;
        _problemDetail = null;
        _statuses = statuses;
        _ticked
          ..clear()
          ..addAll([
            for (var i = 0; i < statuses.length; i++)
              if (statuses[i] == CsvRowStatus.fresh && (_chosen[file.rows[i].line] ?? true)) i,
          ]);
        _busy = false;
      });
      return true;
    } catch (e) {
      if (mounted) _fail(l10n.csvImpCouldNotRead, '$e');
      return false;
    }
  }

  /// Reads [file], where it is a host file; what else it may be is said, and
  /// the right import offered, before anything of it is read as hosts: a
  /// private key above all, of which this keeps nothing.
  Future<void> _take(ImportFile file) async {
    final l10n = AppLocalizations.of(context)!;
    var taken = file;
    if (!file.kind.isHostFile && file.kind != ImportKind.unknown) {
      setState(() => _busy = false);
      final chosen = widget.kind == HostFileKind.paste ? l10n.importPasteTitle : hostFileAppIn(widget.kind, l10n) ?? l10n.cloudImpCsv;
      if (await routeIfOtherFile(context, file, chosen: chosen, takes: const {}, readsHere: true)) return;
      // A text with a private key in it and more, which the person says is
      // for this import all the same.
      taken = await importFileToRead(file);
      if (!mounted) return;
      setState(() => _busy = true);
    }
    final picked = taken.picked;
    // (Nothing to read: the file is only a key now, since it was looked at.)
    if (picked == null) return _fail(l10n.csvImpUnreadable);
    await _read(picked);
  }

  Future<void> _choose() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final stand = widget.pickFile;
      final ImportFile? file;
      if (stand != null) {
        final picked = await stand();
        file = picked == null
            ? null
            : await importFileAway(
                name: picked.name,
                path: widget.pickedPath,
                bytes: picked.bytes,
                rdp: ref.read(rdpOfferedProvider),
              );
      } else {
        file = await pickImportFile(l10n.csvImpChoose, rdp: ref.read(rdpOfferedProvider));
      }
      if (!mounted) return;
      if (file == null) return setState(() => _busy = false);
      await _take(file);
    } catch (e) {
      if (mounted) _fail(l10n.csvImpUnreadable, '$e');
    }
  }

  Future<void> _paste() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      if (!mounted) return;
      final file = await importFileAway(name: l10n.csvImpPasted, bytes: utf8.encode(text), rdp: ref.read(rdpOfferedProvider));
      if (!mounted) return;
      await _take(file);
    } catch (e) {
      if (mounted) _fail(l10n.csvImpUnreadable, '$e');
    }
  }

  Future<void> _pickDestination(ImportDestination d) async {
    final file = _file;
    final before = _destination;
    if (_busy || file == null || d.key == before.key) return;
    setState(() {
      _destination = d;
      _busy = true;
    });
    // What is "already here" depends on where they go; where that cannot be
    // read, they stay where they were going.
    if (!await _plan(file) && mounted) setState(() => _destination = before);
  }

  void _tick(int i, bool on) => setState(() {
        _chosen[_file!.rows[i].line] = on;
        if (on) {
          _ticked.add(i);
        } else {
          _ticked.remove(i);
        }
      });

  Future<void> _import() async {
    final file = _file;
    if (_busy || file == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _importing = true;
    });
    try {
      final db = await importDatabaseOf(ref, _destination);
      if (db == null) throw StateError('no database for ${_destination.key}');
      final outcome = await applyCsvImport(
        CsvImportTarget(
          db: db,
          crateId: _destination.crateId,
          userKeyLabel: l10n.sshConfigImportImportedIdentityLabel,
          compatibilityMode: _compatibility,
          rdpGateway: ref.read(rdpGatewayOfferedProvider),
        ),
        [for (final i in _ticked.toList()..sort()) file.rows[i]],
        passwordsAllowed: _passwordsAllowed,
      );
      if (!mounted) return;
      Navigator.of(context)
          .pop(CsvImportResult(fileName: Redactable.path(_fileName).displayIn(ref), outcome: outcome));
    } catch (e) {
      if (mounted) _fail(l10n.csvImpCouldNotRead, '$e');
    }
  }

  void _another() => setState(() {
        _file = null;
        _readAs = null;
        _place = null;
        _statuses = const [];
        _ticked.clear();
        _passwordsAllowed.clear();
        _problem = null;
        _problemDetail = null;
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final file = _file;
    // Nothing closes it while hosts are being written.
    final importing = _importing;
    // As what it is, once a file is read: chosen as one app, it may be
    // another's.
    final shown = file == null ? widget.kind : (_readAs ?? widget.kind);
    return PopScope(
      canPop: !importing,
      child: ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: switch (shown) {
        HostFileKind.csv => LucideIcons.fileSpreadsheet,
        HostFileKind.paste => LucideIcons.clipboardList,
        _ => LucideIcons.arrowRightLeft,
      },
      title: switch (shown) {
        HostFileKind.paste => l10n.importPasteTitle,
        _ => switch (hostFileAppIn(shown, l10n)) {
            final app? => l10n.migrateTitle(app),
            null => l10n.csvImpTitle,
          },
      },
      subtitle: file == null || widget.kind == HostFileKind.paste ? null : Redactable.path(_fileName).displayIn(ref),
      onClose: importing ? () {} : null,
      body: file == null ? _start(l10n) : _preview(l10n, file),
      primaryAction: file == null
          ? (widget.kind == HostFileKind.paste
              ? (
                  label: l10n.pasteListRead,
                  icon: LucideIcons.listChecks,
                  onPressed: _busy || _pasted.text.trim().isEmpty ? null : _readPasted,
                )
              : null)
          : (
              label: importing ? l10n.cloudImpImporting : l10n.cloudImpImportN(_ticked.length),
              icon: LucideIcons.download,
              onPressed: _ticked.isEmpty || _busy ? null : _import,
            ),
      secondaryAction: (label: l10n.cancel, onPressed: importing ? null : () => Navigator.of(context).pop()),
      tertiaryAction: file == null
          ? null
          : (
              label: widget.kind == HostFileKind.paste ? l10n.pasteListEdit : l10n.csvImpAnother,
              onPressed: _busy ? null : _another,
            ),
      ),
    );
  }

  /// What to choose and what comes in. The programs that keep Remote Desktop
  /// connections say those come in too, where this build offers RDP hosts.
  String _helpOf(AppLocalizations l10n) {
    final help = switch (widget.kind) {
      HostFileKind.csv => l10n.csvImpHelp,
      HostFileKind.mobaxterm => l10n.migrateMobaHelp,
      HostFileKind.securecrt => l10n.migrateCrtHelp,
      HostFileKind.putty => l10n.migratePuttyHelp,
      HostFileKind.filezilla => l10n.migrateFileZillaHelp,
      HostFileKind.winscp => l10n.migrateWinScpHelp,
      HostFileKind.mremoteng => l10n.migrateMRemoteNgHelp,
      HostFileKind.remmina => l10n.migrateRemminaHelp,
      HostFileKind.rdpfile => l10n.migrateRdpFileHelp,
      HostFileKind.paste => l10n.pasteListHelp,
    };
    const keepRdp = {HostFileKind.mobaxterm, HostFileKind.mremoteng, HostFileKind.remmina};
    return keepRdp.contains(widget.kind) && ref.watch(rdpOfferedProvider) ? '$help ${l10n.migrateHelpRdpToo}' : help;
  }

  Widget _start(AppLocalizations l10n) => widget.kind == HostFileKind.paste ? _startPaste(l10n) : Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              _helpOf(l10n),
              key: const ValueKey('csv-help'),
              style: TextStyle(fontSize: 12.5, height: 1.5, color: ZestTokens.textSecondary)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              ZestButton(
                key: const ValueKey('csv-choose'),
                label: l10n.csvImpChoose,
                icon: LucideIcons.fileUp,
                variant: ZestButtonVariant.primary,
                isLoading: _busy,
                onPressed: _busy ? null : _choose,
              ),
              ZestButton(
                key: const ValueKey('csv-paste'),
                label: l10n.sshImportPasteFromClipboard,
                icon: LucideIcons.clipboardPaste,
                onPressed: _busy ? null : _paste,
              ),
            ],
          ),
          if (_problem case final problem?) ...[
            const SizedBox(height: 14),
            _Problem(message: problem, detail: _problemDetail),
          ],
        ],
      );

  /// Paste a list: what a line may be, and the field.
  Widget _startPaste(AppLocalizations l10n) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.pasteListHelp,
              key: const ValueKey('csv-help'), style: TextStyle(fontSize: 12.5, height: 1.5, color: ZestTokens.textSecondary)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('paste-list-field'),
            controller: _pasted,
            onChanged: (_) => setState(() {}),
            minLines: 8,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.5, color: ZestTokens.textPrimary),
            decoration: InputDecoration(hintText: l10n.pasteListHint),
          ),
          if (_problem case final problem?) ...[
            const SizedBox(height: 12),
            _Problem(message: problem, detail: _problemDetail),
          ],
        ],
      );

  Widget _preview(AppLocalizations l10n, CsvHostFile file) {
    final here = _statuses.where((s) => s == CsvRowStatus.here).length;
    final problems = _statuses.where((s) => s == CsvRowStatus.problem).length;
    final selectable = [for (var i = 0; i < _statuses.length; i++) if (_statuses[i] == CsvRowStatus.fresh) i];
    final allOn = selectable.isNotEmpty && selectable.every(_ticked.contains);
    final readAs = _readAs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Chosen as one kind, and it is another: read as what it is, and said.
        if (readAs != null && readAs != widget.kind && widget.kind != HostFileKind.paste) ...[
          Text(
            l10n.importReadAsOther(hostFileAppIn(readAs, l10n) ?? l10n.cloudImpCsv, hostFileAppIn(widget.kind, l10n) ?? l10n.cloudImpCsv),
            key: const ValueKey('csv-read-as'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
          ),
          const SizedBox(height: 8),
        ],
        if (_destinations.length > 1) ...[
          ImportGroupLabel(l10n.cloudImpWhere),
          for (final d in _destinations)
            ImportSourceTile(
              key: ValueKey('csv-destination-${d.key}'),
              selected: d.key == _destination.key,
              title: d.isTree ? l10n.cloudImpTree : '${d.orchardName}, ${d.crateName}',
              subtitle: d.isTree ? l10n.cloudImpTreeDesc : l10n.cloudImpCrateDesc(d.crateName!),
              onTap: () => _pickDestination(d),
            ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.csvImpFound(file.rows.length, here, problems),
                key: const ValueKey('csv-found'),
                style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
              ),
            ),
            if (selectable.isNotEmpty)
              TextButton(
                key: const ValueKey('csv-all'),
                onPressed: _busy
                    ? null
                    : () {
                        for (final i in selectable) {
                          _tick(i, !allOn);
                        }
                      },
                child: Text(allOn ? l10n.sshImportDeselectAll : l10n.sshImportSelectAll),
              ),
          ],
        ),
        if (file.ignored.isNotEmpty)
          RedactedText(Redactable.freeText(l10n.csvImpIgnored(file.ignored.join(', '))),
              key: const ValueKey('csv-ignored'), style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
        // What the file asked for and the host will not do, before anything
        // is imported. (A gateway's address is a host's: hidden in recording mode.)
        for (final note in file.notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: switch (note) {
              // Where this build offers gateways the host goes through it (4.0);
              // else it connects directly, which the note warns of.
              HostFileNote.rdpGateway when ref.watch(rdpGatewayOfferedProvider) && file.rows.any((r) => r.gateway != null) => RedactedText(
                  Redactable.freeText(l10n.rdpFileNoteGatewayKept(file.gateway ?? '')),
                  key: const ValueKey('csv-note-rdpGateway-kept'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary),
                ),
              HostFileNote.rdpGateway => RedactedText(
                  Redactable.freeText(l10n.rdpFileNoteGateway(file.gateway ?? '')),
                  key: const ValueKey('csv-note-rdpGateway'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusWarning),
                ),
              _ => Text(
                  switch (note) {
                    HostFileNote.rdpPassword => l10n.rdpFileNotePassword,
                    HostFileNote.rdpProgram => l10n.rdpFileNoteProgram,
                    HostFileNote.rdpNlaOff || HostFileNote.rdpGateway => l10n.rdpFileNoteNla,
                  },
                  key: ValueKey('csv-note-${note.name}'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary),
                ),
            },
          ),
        if (file.cut)
          Text(l10n.csvImpCut(kCsvMaxHosts),
              key: const ValueKey('csv-cut'), style: TextStyle(fontSize: 12, color: ZestTokens.statusWarning)),
        // FTP comes in as FTPS, never as plain FTP: said before anything is
        // imported, with how many.
        if (file.rows.where((r) => r.isFtps).length case final ftps when ftps > 0)
          Text(
            l10n.csvImpFtpsNote(ftps),
            key: const ValueKey('csv-ftps-note'),
            style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary),
          ),
        if (_problem case final problem?) ...[
          const SizedBox(height: 8),
          _Problem(message: problem, detail: _problemDetail),
        ],
        const SizedBox(height: 8),
        // A file may hold thousands: only the rows on screen are built.
        SizedBox(
          // (A row that asks about a password is the taller for it.)
          height: ((file.rows.length * 64.0) +
                  (_place == null
                      ? 0
                      : file.rows
                              .where((r) => _place!.passwordKeyOf(r, userKeyLabel: l10n.sshConfigImportImportedIdentityLabel) != null)
                              .length *
                          56.0))
              .clamp(64.0, 360.0),
          child: ListView.builder(
            itemCount: file.rows.length,
            itemBuilder: (context, i) => _HostRow(
              key: ValueKey('csv-row-${file.rows[i].line}'),
              row: file.rows[i],
              status: _statuses[i],
              place: _place,
              ticked: _ticked.contains(i),
              onChanged: _statuses[i] == CsvRowStatus.fresh && !_busy ? (on) => _tick(i, on) : null,
              passwordAllowed: _passwordsAllowed.contains(file.rows[i].line),
              onPasswordAllowed: _busy
                  ? null
                  : (on) => setState(() => on ? _passwordsAllowed.add(file.rows[i].line) : _passwordsAllowed.remove(file.rows[i].line)),
            ),
          ),
        ),
        // For a file of old servers: Compatibility mode on all of them at
        // once, rather than host by host afterwards. Off unless ticked, and
        // said as not recommended, as in the host editor.
        if (selectable.isNotEmpty) ...[
          const SizedBox(height: 8),
          ImportCompatibilityOption(
            key: const ValueKey('csv-compatibility'),
            value: _compatibility,
            onChanged: _busy ? null : (v) => setState(() => _compatibility = v),
          ),
        ],
      ],
    );
  }
}

/// What an imported FTPS host is called: FTPS, or FTPS with implicit TLS.
String _ftpsName(String protocol, AppLocalizations l10n) =>
    (protocol == ConnectionProtocol.ftpsImplicit.name ? ConnectionProtocol.ftpsImplicit : ConnectionProtocol.ftps).nameIn(l10n);

/// Why a file could not be read, with its details to copy where there are.
class _Problem extends StatelessWidget {
  const _Problem({required this.message, required this.detail});
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final detail = this.detail;
    return Container(
      key: const ValueKey('csv-problem'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZestTokens.statusCritical.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.statusCritical.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.alertCircle, size: 15, color: ZestTokens.statusCritical),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textPrimary))),
            ],
          ),
          if (detail != null)
            Align(alignment: Alignment.centerRight, child: CopyDetailsButton(detail: detail, label: l10n.desktopShellCopyDetails)),
        ],
      ),
    );
  }
}

/// One host of the file: tick, name, address, how it signs in and where it
/// goes, and what an import does with it.
class _HostRow extends ConsumerWidget {
  const _HostRow({
    super.key,
    required this.row,
    required this.status,
    required this.place,
    required this.ticked,
    required this.onChanged,
    required this.passwordAllowed,
    required this.onPasswordAllowed,
  });

  final CsvHostRow row;
  final CsvRowStatus status;
  final CsvPlace? place;
  final bool ticked;
  final ValueChanged<bool>? onChanged;

  /// Whether this host may be sent the password its key holds.
  final bool passwordAllowed;
  final ValueChanged<bool>? onPasswordAllowed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final (kind, label) = switch (status) {
      CsvRowStatus.fresh => (ZestStatusKind.healthy, l10n.cloudImpStNew),
      CsvRowStatus.here => (ZestStatusKind.neutral, l10n.cloudImpStHere),
      CsvRowStatus.twice => (ZestStatusKind.neutral, l10n.csvImpTwice),
      CsvRowStatus.problem => (
          ZestStatusKind.critical,
          switch (row.problem) {
            CsvRowProblem.noHost => l10n.csvImpNoHost,
            CsvRowProblem.badHost => l10n.csvImpBadHost,
            CsvRowProblem.badPort => l10n.csvImpBadPort,
            CsvRowProblem.badProtocol || null => l10n.csvImpBadProtocol,
          }
        ),
    };
    // How it signs in: the key the file names where it is here, else the
    // user it names.
    final named = row.key;
    final found = named == null ? null : place?.keyNamed(named);
    final key = found?.key;
    final user = row.user;
    final signIn = key != null
        ? '${Redactable.keyName(key.label).displayIn(ref)} (${Redactable.username(key.user).displayIn(ref)})'
        : (user == null ? null : Redactable.username(user).displayIn(ref));
    final details = [
      ?signIn,
      if (row.group case final group?) Redactable.group(group).displayIn(ref),
      if (row.tags.isNotEmpty) Redactable.freeText(row.tags.join(', ')).displayIn(ref),
      if (row.isFtps)
        row.wasPlainFtp ? l10n.csvImpFtpAsFtps(_ftpsName(row.protocol, l10n)) : _ftpsName(row.protocol, l10n)
      else if (row.protocol != 'ssh')
        row.protocol,
    ].join(' · ');
    final keyNote = switch (found?.problem) {
      CsvKeyProblem.missing => l10n.csvImpKeyMissing(Redactable.keyName(named!).displayIn(ref)),
      CsvKeyProblem.twice => l10n.csvImpKeyTwice(Redactable.keyName(named!).displayIn(ref)),
      CsvKeyProblem.watched => l10n.csvImpKeyWatched(Redactable.keyName(named!).displayIn(ref)),
      null => null,
    };
    // A key that would send this host a password that is yours says so, and asks
    // for this host alone: the file names the key and the address both.
    final passwordKey = status == CsvRowStatus.fresh
        ? place?.passwordKeyOf(row, userKeyLabel: l10n.sshConfigImportImportedIdentityLabel)
        : null;
    // A line that is no host says which line it is, with what it holds.
    final name = row.name.isEmpty
        ? l10n.csvImpLine(row.line)
        : row.problem != null
            ? '${l10n.csvImpLine(row.line)} · ${row.name}'
            : row.name;
    final address = row.host.isEmpty ? '' : (row.port == 22 ? row.host : hostWithPort(row.host, row.port));
    final pill = ZestStatusPill(key: ValueKey('csv-status-${row.line}'), kind: kind, label: label);
    final tick = SizedBox(
      width: 32,
      height: 32,
      child: status != CsvRowStatus.fresh
          ? null
          : Checkbox(
              value: ticked,
              activeColor: ZestTokens.brand,
              checkColor: const Color(0xFF1A0D04),
              side: BorderSide(color: ZestTokens.borderStrong),
              onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
            ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Flexible(
            child: RedactedText(Redactable.host(name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
          ),
          if (address.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: RedactedText(Redactable.address(address),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textSecondary)),
            ),
          ],
        ]),
        if (details.isNotEmpty)
          Text(details,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
        if (keyNote != null)
          Text(keyNote,
              key: ValueKey('csv-key-note-${row.line}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: ZestTokens.statusWarning)),
        // On the row's own Material: the row's tint would hide its ink on the list's.
        if (passwordKey != null)
          InkLayer(
            child: CheckboxListTile(
            key: ValueKey('csv-key-password-${row.line}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: passwordAllowed,
            onChanged: onPasswordAllowed == null ? null : (on) => onPasswordAllowed!(on ?? false),
            title: Text(
              l10n.csvImpKeyPassword(
                Redactable.keyName(passwordKey.label).displayIn(ref),
                Redactable.address(address).displayIn(ref),
              ),
              style: TextStyle(fontSize: 11.5, color: ZestTokens.statusWarning),
            ),
          ),
          ),
      ],
    );
    return Opacity(
      opacity: status == CsvRowStatus.fresh ? 1 : 0.6,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!ticked),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
          decoration: BoxDecoration(
            color: ticked ? AppColors.v3AccentPrimary.withValues(alpha: 0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ticked ? AppColors.v3AccentPrimary.withValues(alpha: 0.35) : ZestTokens.borderSubtle, width: 0.5),
          ),
          child: Row(
            children: [
              tick,
              const SizedBox(width: 6),
              Expanded(child: text),
              const SizedBox(width: 8),
              pill,
            ],
          ),
        ),
      ),
    );
  }
}
