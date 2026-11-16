import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_aws.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_import_writer.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_provider_info.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_identity.dart' show WorkspaceDashedBox;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart' show ParsedConnectionShare;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart' show puttyImportHere;
import 'package:zestssh/ui/screens/connection/share_link_add.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// What "Import hosts" (3.0) ended with: a file source to open next, or a
/// cloud import that is done.
sealed class ImportHostsResult {
  const ImportHostsResult();
}

/// Import a file: [file], chosen here, to go to the import of [kind]: what it
/// was found to be, or what the person said it is.
class ImportFromFile extends ImportHostsResult {
  const ImportFromFile({required this.file, required this.kind});
  final ImportFile file;
  final ImportKind kind;
}

/// Open the SSH config import next.
class ImportFromSshConfig extends ImportHostsResult {
  const ImportFromSshConfig();
}

/// Open the PuTTY sessions import next (Windows).
class ImportFromPutty extends ImportHostsResult {
  const ImportFromPutty();
}

/// Open the host file import next: a CSV file, or another app's own file
/// (MobaXterm, SecureCRT, PuTTY's .reg).
class ImportFromCsv extends ImportHostsResult {
  const ImportFromCsv({this.kind = HostFileKind.csv});
  final HostFileKind kind;
}

/// Open the guide to moving from Termius next (it has no export; a free
/// tool writes an SSH config file, which the SSH config import reads).
class ImportTermiusGuide extends ImportHostsResult {
  const ImportTermiusGuide();
}

/// Open "Suggest something" next: the source the person wanted is not here.
class ImportAskForSource extends ImportHostsResult {
  const ImportAskForSource();
}

/// Pick a host shared from ZestSSH as a `.zest` file next.
class ImportFromZest extends ImportHostsResult {
  const ImportFromZest();
}

/// Add a host from its share link next (`zestssh://share?d=...` or
/// `zestssh://add-host?...`): the one on the clipboard ([reading]), shown at
/// once for the person to add or not, or, with none, the field to paste one.
class ImportFromShareLink extends ImportHostsResult {
  const ImportFromShareLink({this.reading});
  final ShareLinkReading? reading;
}

/// A cloud import was written.
class ImportedFromCloud extends ImportHostsResult {
  const ImportedFromCloud({required this.account, required this.outcome, required this.kept, this.keptError});
  final String account;
  final CloudImportOutcome outcome;
  final bool kept;

  /// Why Keep in sync could not be saved (the hosts are imported anyway).
  final String? keptError;
}

/// Opens "Import hosts": pick files or a cloud account, choose hosts, choose
/// where they go.
Future<ImportHostsResult?> showImportHostsDialog(BuildContext context, {bool chooseFile = false}) =>
    showZestModal<ImportHostsResult>(
      context: context,
      size: ZestModalSize.large,
      barrierDismissible: false,
      child: ImportHostsDialog(chooseFile: chooseFile),
    );

enum _Step { source, connect, choose, destination }

enum _FileSource {
  sshConfig,
  putty,
  puttyFile,
  mobaxterm,
  securecrt,
  filezilla,
  winscp,
  mremoteng,
  remmina,
  rdpFile,
  termius,
  csv,
  zest,
  shareLink,
  paste,
}

/// A place imported hosts can go: the Tree, or a Crate this account may add
/// to in one of its Orchards.
class ImportDestination {
  const ImportDestination.tree() : orchardId = null, orchardName = null, crateId = null, crateName = null;
  const ImportDestination.crate({required String this.orchardId, required this.orchardName, required String this.crateId, required this.crateName});

  final String? orchardId;
  final String? orchardName;
  final String? crateId;
  final String? crateName;

  bool get isTree => orchardId == null;
  String get key => isTree ? kCloudTreeSpace : '$orchardId/$crateId';
  Space get space => isTree ? const TreeSpace() : OrchardSpace(orchardId!);
}

/// Where imported hosts can go: the Tree, and each Crate this account may
/// add to in its Orchards.
Future<List<ImportDestination>> importDestinations(WidgetRef ref) async {
  final out = <ImportDestination>[const ImportDestination.tree()];
  if (kOrchardsEnabled) {
    try {
      for (final o in await ref.read(orchardSummariesProvider.future)) {
        for (final c in o.crates) {
          if (c.name != null && c.switches.contains(CrateSwitches.add)) {
            out.add(ImportDestination.crate(orchardId: o.id, orchardName: o.name ?? '', crateId: c.id, crateName: c.name!));
          }
        }
      }
    } catch (_) {/* the Tree is always there */}
  }
  return out;
}

/// The database of the space [d] is in.
Future<AppDatabase?> importDatabaseOf(WidgetRef ref, ImportDestination d) async {
  if (d.isTree) return ref.read(databaseSessionProvider);
  return ref.read(orchardDatabasesProvider.notifier).open(d.orchardId!);
}

class ImportHostsDialog extends ConsumerStatefulWidget {
  const ImportHostsDialog({super.key, this.scan, this.probe, this.readClipboard, this.pickFile, this.chooseFile = false});

  /// Stand-ins for tests.
  final Future<List<CloudMachine>> Function(CloudProvider, Map<String, String>)? scan;
  final Future<CloudCertificate?> Function(Uri base)? probe;

  /// Reads the clipboard, for a share link on it ([readClipboardText]
  /// otherwise). Only where that is silent ([clipboardReadIsSilent]).
  final Future<String?> Function()? readClipboard;

  /// Chooses a file for Import a file ([pickImportFile] otherwise).
  final Future<ImportFile?> Function()? pickFile;

  /// Opens at Import a file's question, which file (the phone's Import data
  /// sheet has the action itself).
  final bool chooseFile;

  @override
  ConsumerState<ImportHostsDialog> createState() => _ImportHostsDialogState();
}

class _ImportHostsDialogState extends ConsumerState<ImportHostsDialog> {
  _Step _step = _Step.source;
  _FileSource? _file;
  CloudProvider? _provider;

  final _label = TextEditingController();
  final _fields = <String, TextEditingController>{};
  final _fieldErrors = <String, String>{};
  bool _keep = false;
  bool _howTo = false;

  bool _busy = false;
  CloudError? _error;

  // Proxmox's own certificate, waiting for the person to compare it.
  CloudCertificate? _certificate;
  final _pastedFingerprint = TextEditingController();
  String? _pin;

  List<CloudMachine> _machines = const [];
  List<CloudRow> _rows = const [];
  final Set<int> _ticked = {};

  /// What the person ticked or unticked themselves, by machine (or host for
  /// a gone row): kept when the table is worked out again.
  final Map<String, bool> _chosen = {};
  bool _preferPrivate = false;

  List<ImportDestination> _destinations = const [ImportDestination.tree()];
  ImportDestination _destination = const ImportDestination.tree();
  List<Identity> _identities = const [];
  String? _identityId;
  final _group = TextEditingController();

  /// A share link that was on the clipboard as this opened, offered first.
  ShareLinkReading? _clipboardLink;

  /// Compatibility mode for every host imported (off unless ticked).
  bool _compatibility = false;

  /// The file chosen under Import a file, and what the person said it is
  /// where they corrected the detector.
  ImportFile? _found;
  ImportKind? _foundAs;
  bool _readingFile = false;

  /// A file that could not be read: what to say, and the details.
  ({String said, Object cause})? _fileProblem;

  @override
  void initState() {
    super.initState();
    _pastedFingerprint.addListener(() => setState(() {}));
    unawaited(_lookOnClipboard());
    if (widget.chooseFile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_chooseFile());
      });
    }
  }

  /// A host's share link on the clipboard is offered at the top, where
  /// reading the clipboard is silent: never where the system would say so or
  /// ask (an iPhone's banner), there Paste a share link reads it on a tap.
  /// What is on it is not kept or logged; only a link that reads is offered.
  Future<void> _lookOnClipboard() async {
    if (!clipboardReadIsSilent()) return;
    final text = await (widget.readClipboard ?? readClipboardText)();
    if (!mounted || text == null || !looksLikeShareLink(text)) return;
    final reading = readShareLink(text);
    if (reading.ok) setState(() => _clipboardLink = reading);
  }

  @override
  void dispose() {
    _label.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    _pastedFingerprint.dispose();
    _group.dispose();
    super.dispose();
  }

  TextEditingController _field(String key) => _fields.putIfAbsent(key, TextEditingController.new);

  Map<String, String> get _values => {
        for (final e in _fields.entries) e.key: e.value.text.trim(),
        CloudField.pin: ?_pin,
      };

  // ── Source ────────────────────────────────────────────────────────────────

  Future<void> _next() async {
    switch (_step) {
      case _Step.source:
        if (_file == _FileSource.sshConfig) return Navigator.of(context).pop(const ImportFromSshConfig());
        if (_file == _FileSource.putty) return Navigator.of(context).pop(const ImportFromPutty());
        if (_file == _FileSource.puttyFile) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.putty));
        if (_file == _FileSource.csv) return Navigator.of(context).pop(const ImportFromCsv());
        if (_file == _FileSource.mobaxterm) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.mobaxterm));
        if (_file == _FileSource.securecrt) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.securecrt));
        if (_file == _FileSource.filezilla) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.filezilla));
        if (_file == _FileSource.winscp) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.winscp));
        if (_file == _FileSource.mremoteng) {
          return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.mremoteng));
        }
        if (_file == _FileSource.remmina) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.remmina));
        if (_file == _FileSource.rdpFile) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.rdpfile));
        if (_file == _FileSource.zest) return Navigator.of(context).pop(const ImportFromZest());
        if (_file == _FileSource.shareLink) return Navigator.of(context).pop(const ImportFromShareLink());
        if (_file == _FileSource.termius) return Navigator.of(context).pop(const ImportTermiusGuide());
        if (_file == _FileSource.paste) return Navigator.of(context).pop(const ImportFromCsv(kind: HostFileKind.paste));
        final provider = _provider;
        if (provider == null) return;
        // Typing tokens and addresses paints them on screen: the recording
        // mode gate first.
        if (!await confirmRevealWhileRecording(context, ref)) return;
        if (!mounted) return;
        setState(() {
          if (_label.text.trim().isEmpty) _label.text = cloudProviderName(provider);
          _step = _Step.connect;
          _error = null;
        });
      case _Step.connect:
        await _scan();
      case _Step.choose:
        await _loadDestinations();
        if (mounted) setState(() => _step = _Step.destination);
      case _Step.destination:
        await _import();
    }
  }

  /// Import a file: the person chooses one, and what it is is said.
  Future<void> _chooseFile() => _readFile(() => (widget.pickFile ??
      () => pickImportFile(AppLocalizations.of(context)!.importFileAction, rdp: ref.read(rdpOfferedProvider)))());

  /// Reads the file [choose] gives, and says what it is.
  Future<void> _readFile(Future<ImportFile?> Function() choose) async {
    if (_readingFile) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _readingFile = true);
    try {
      final file = await choose();
      if (!mounted) return;
      setState(() {
        _readingFile = false;
        if (file != null) {
          _found = file;
          _foundAs = null;
          _fileProblem = null;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _readingFile = false;
          _fileProblem = (said: l10n.csvImpUnreadable, cause: e);
        });
      }
    }
  }

  void _back() => setState(() {
        _error = null;
        _certificate = null;
        _step = switch (_step) {
          _Step.source || _Step.connect => _Step.source,
          _Step.choose => _Step.connect,
          _Step.destination => _Step.choose,
        };
      });

  // ── Connect ───────────────────────────────────────────────────────────────

  bool _validate(AppLocalizations l10n) {
    final provider = _provider!;
    _fieldErrors.clear();
    for (final f in cloudFieldsOf(l10n, provider)) {
      if (!f.optional && _field(f.key).text.trim().isEmpty) _fieldErrors[f.key] = l10n.cloudImpNeedField;
    }
    final v = _values;
    switch (provider) {
      case CloudProvider.aws:
        if (awsRegionsOf(v[CloudField.regions] ?? '') == null) _fieldErrors[CloudField.regions] = l10n.cloudImpBadRegions;
      case CloudProvider.azure:
        if (!looksLikeAzureAccessToken(v[CloudField.secret] ?? '')) {
          for (final k in [CloudField.tenant, CloudField.clientId]) {
            if ((v[k] ?? '').isEmpty) _fieldErrors[k] = l10n.cloudImpNeedField;
          }
        }
      case CloudProvider.proxmox:
        if ((v[CloudField.url] ?? '').isNotEmpty && proxmoxBase(v[CloudField.url]!) == null) {
          _fieldErrors[CloudField.url] = l10n.cloudImpBadUrl;
        }
        if ((v[CloudField.token] ?? '').isNotEmpty && proxmoxTokenValue(v[CloudField.token]!) == null) {
          _fieldErrors[CloudField.token] = l10n.cloudImpBadProxmoxToken;
        }
      case CloudProvider.digitalocean || CloudProvider.hetzner || CloudProvider.tailscale:
        break;
    }
    setState(() {});
    return _fieldErrors.isEmpty;
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy || !_validate(l10n)) return;
    final provider = _provider!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Proxmox: its own certificate is compared by the person before
      // anything is sent to it.
      if (provider == CloudProvider.proxmox && _pin == null) {
        final base = proxmoxBase(_values[CloudField.url]!)!;
        final cert = await (widget.probe ?? probeCertificate)(base);
        if (!mounted) return;
        if (cert != null) {
          setState(() {
            _certificate = cert;
            _busy = false;
          });
          return;
        }
      }
      final machines = await (widget.scan ?? scanCloud)(provider, _values);
      if (!mounted) return;
      _chosen.clear();
      await _plan(machines);
      if (mounted) setState(() => _step = _Step.choose);
    } on CloudError catch (e) {
      if (mounted) setState(() => _error = e);
    } catch (e) {
      if (mounted) setState(() => _error = CloudError(CloudErrorKind.answer, detail: '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trustCertificate() async {
    final cert = _certificate;
    if (cert == null) return;
    setState(() {
      _pin = cert.sha256;
      _certificate = null;
    });
    await _scan();
  }

  Future<AppDatabase?> _databaseOf(ImportDestination d) => importDatabaseOf(ref, d);

  Future<void> _plan(List<CloudMachine> machines) async {
    final db = await _databaseOf(_destination);
    final hosts = db == null ? const <CloudExistingHost>[] : await cloudExistingHosts(db);
    final rows = planCloudImport(
      provider: _provider!,
      machines: machines,
      hosts: hosts,
      label: _label.text.trim(),
      preferPrivate: _preferPrivate,
    );
    if (!mounted) return;
    setState(() {
      _machines = machines;
      _rows = rows;
      _ticked
        ..clear()
        ..addAll([
          for (var i = 0; i < rows.length; i++)
            if (rows[i].selectable && (_chosen[_rowKey(rows[i])] ?? rows[i].selected)) i,
        ]);
    });
  }

  static String _rowKey(CloudRow r) => r.machine?.id ?? 'host:${r.existing?.id}';

  void _tick(int i, bool on) => setState(() {
        _chosen[_rowKey(_rows[i])] = on;
        if (on) {
          _ticked.add(i);
        } else {
          _ticked.remove(i);
        }
      });

  // ── Destination ───────────────────────────────────────────────────────────

  Future<void> _loadDestinations() async {
    final out = await importDestinations(ref);
    if (_group.text.isEmpty) _group.text = _label.text.trim();
    if (!mounted) return;
    setState(() {
      _destinations = out;
      if (!out.any((d) => d.key == _destination.key)) _destination = out.first;
    });
    await _loadIdentities();
  }

  Future<void> _loadIdentities() async {
    final db = await _databaseOf(_destination);
    final identities = db == null ? const <Identity>[] : await db.identitiesDao.getAll();
    if (!mounted) return;
    setState(() {
      _identities = identities;
      if (!identities.any((i) => i.id == _identityId)) {
        _identityId = identities.where((i) => i.isDefault).firstOrNull?.id;
      }
    });
  }

  Future<void> _pickDestination(ImportDestination d) async {
    setState(() => _destination = d);
    await _loadIdentities();
    // What is "already here" depends on where they go.
    await _plan(_machines);
  }

  Future<void> _import() async {
    if (_busy) return;
    final db = await _databaseOf(_destination);
    if (db == null || !mounted) return;
    setState(() => _busy = true);
    final label = _label.text.trim();
    final chosen = [
      for (var i = 0; i < _rows.length; i++)
        if ((_ticked.contains(i) && _rows[i].selectable) || _rows[i].status == CloudRowStatus.gone) _rows[i],
    ];
    final outcome = await applyCloudImport(
      CloudImportTarget(
        db: db,
        label: label,
        crateId: _destination.crateId,
        identityId: _identityId,
        groupName: _group.text.trim().isEmpty ? null : _group.text.trim(),
        preferPrivate: _preferPrivate,
        compatibilityMode: _compatibility,
      ),
      chosen,
    );
    String? keptError;
    if (_keep) {
      try {
        await ref.read(cloudAccountsProvider.notifier).keep(CloudAccount(
            id: const Uuid().v4(),
            provider: _provider!,
            label: label,
            fields: _values,
            spaceId: _destination.isTree ? kCloudTreeSpace : _destination.orchardId!,
            crateId: _destination.crateId,
            identityId: _identityId,
            groupName: _group.text.trim().isEmpty ? null : _group.text.trim(),
            preferPrivate: _preferPrivate,
            checkedAt: DateTime.now(),
            found: _machines.length,
          ));
      } catch (e) {
        // The hosts are in; only the checks later could not be set up.
        keptError = '$e';
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(ImportedFromCloud(account: label, outcome: outcome, kept: _keep && keptError == null, keptError: keptError));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  int get _toImport => _ticked.where((i) => i < _rows.length && _rows[i].selectable).length;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    final cloud = provider != null && _file == null;
    final names = cloud || _step != _Step.source
        ? [l10n.cloudImpStepSource, l10n.cloudImpStepConnect, l10n.cloudImpStepChoose, l10n.cloudImpStepDestination]
        : [l10n.cloudImpStepSource, l10n.cloudImpStepChoose, l10n.cloudImpStepDestination];
    final body = switch (_step) {
      _Step.source => _sourceBody(l10n),
      _Step.connect => _connectBody(l10n, provider!),
      _Step.choose => _chooseBody(l10n, provider!),
      _Step.destination => _destinationBody(l10n, provider!),
    };
    final ({String label, VoidCallback? onPressed, IconData? icon})? primary = switch (_step) {
      // A source row goes straight on: no Next.
      _Step.source => null,
      _Step.connect when _certificate != null => (
          label: l10n.cloudImpCertTrust,
          icon: LucideIcons.shieldCheck,
          onPressed: _busy || _fingerprintMismatch ? null : _trustCertificate,
        ),
      _Step.connect => (label: _busy ? l10n.cloudImpScanning : l10n.cloudImpScan, icon: LucideIcons.search, onPressed: _busy ? null : _next),
      _Step.choose => (label: l10n.cloudImpNext, icon: LucideIcons.arrowRight, onPressed: _toImport > 0 || _hasGone ? _next : null),
      _Step.destination => (
          label: _busy
              ? l10n.cloudImpImporting
              : (_toImport > 0 ? l10n.cloudImpImportN(_toImport) : l10n.cloudImpMarkGoneN(_rows.where((r) => r.status == CloudRowStatus.gone).length)),
          icon: LucideIcons.download,
          onPressed: _busy ? null : _next,
        ),
    };
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.download,
      title: l10n.cloudImpTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeader(names: names, current: names.length == 3 ? 0 : _step.index),
          // The steps stand apart from the section under them (its head sat
          // close under them).
          const SizedBox(key: ValueKey('cloud-steps-gap'), height: 24),
          body,
        ],
      ),
      primaryAction: primary,
      secondaryAction: _step == _Step.source
          ? (label: l10n.cancel, onPressed: () => Navigator.of(context).pop())
          : (label: l10n.cloudImpBack, onPressed: _busy ? null : _back),
      // What is not here: one line beside Cancel on a computer (a phone's
      // sheet says it at the end of the step).
      footerLeading: _step == _Step.source && !ZestSheetScope.of(context)
          ? _AskForSource(onTap: () => Navigator.of(context).pop(const ImportAskForSource()))
          : null,
    );
  }

  bool get _hasGone => _rows.any((r) => r.status == CloudRowStatus.gone);

  bool get _fingerprintMismatch {
    final typed = _pastedFingerprint.text.trim();
    if (typed.isEmpty) return false;
    final pasted = normalizeFingerprint(typed);
    return pasted == null || pasted != _certificate?.sha256;
  }

  /// A label column wide enough for the longest of [labels] in this
  /// language, within reason on a narrow screen (a field's label cell pads
  /// 11 on each side and draws at 12).
  double _labelColumn(BuildContext context, List<String> labels) {
    final style = DefaultTextStyle.of(context).style.merge(const TextStyle(fontSize: 12, height: 1.2));
    var widest = 0.0;
    for (final l in labels) {
      final painter = TextPainter(
        text: TextSpan(text: l, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    final most = MediaQuery.sizeOf(context).width * 0.42;
    return (widest + 26).clamp(120.0, most < 120 ? 120.0 : (most > 240 ? 240.0 : most));
  }

  Widget _sourceBody(AppLocalizations l10n) {
    void file(_FileSource f) {
      setState(() {
        _file = f;
        _provider = null;
      });
      _next();
    }

    void cloud(CloudProvider p) {
      setState(() {
        _provider = p;
        _file = null;
      });
      _next();
    }

    // The apps, a tile each with its monogram in its own colour; the file
    // formats with a plain icon (4.0).
    final apps = <Widget>[
      ImportSourceCard(
        key: const ValueKey('file-source-ssh-config'),
        icon: LucideIcons.terminal,
        title: l10n.cloudImpSshConfig,
        subtitle: l10n.cloudImpSshConfigDesc,
        onTap: () => file(_FileSource.sshConfig),
      ),
      // This PC's registry on Windows; elsewhere a file exported from one.
      if (puttyImportHere)
        ImportSourceCard(
          key: const ValueKey('file-source-putty'),
          mark: 'PT',
          title: l10n.cloudImpPutty,
          subtitle: l10n.cloudImpPuttyDesc,
          onTap: () => file(_FileSource.putty),
        )
      else
        ImportSourceCard(
          key: const ValueKey('file-source-putty-file'),
          mark: 'PT',
          title: l10n.cloudImpPutty,
          subtitle: l10n.cloudImpPuttyFileDesc,
          onTap: () => file(_FileSource.puttyFile),
        ),
      ImportSourceCard(
        key: const ValueKey('file-source-mobaxterm'),
        mark: 'MX',
        title: 'MobaXterm',
        subtitle: l10n.migrateMobaDesc,
        onTap: () => file(_FileSource.mobaxterm),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-securecrt'),
        mark: 'CRT',
        title: 'SecureCRT',
        subtitle: l10n.importSecureCrtDesc,
        onTap: () => file(_FileSource.securecrt),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-filezilla'),
        mark: 'FZ',
        title: 'FileZilla',
        subtitle: l10n.migrateFileZillaDesc,
        onTap: () => file(_FileSource.filezilla),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-winscp'),
        mark: 'WS',
        title: 'WinSCP',
        subtitle: l10n.migrateWinScpDesc,
        onTap: () => file(_FileSource.winscp),
      ),
      // Programs that keep remote desktop connections (4.0).
      ImportSourceCard(
        key: const ValueKey('file-source-mremoteng'),
        mark: 'MR',
        title: 'mRemoteNG',
        subtitle: l10n.migrateMRemoteNgDesc,
        onTap: () => file(_FileSource.mremoteng),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-remmina'),
        mark: 'RM',
        title: 'Remmina',
        subtitle: l10n.migrateRemminaDesc,
        onTap: () => file(_FileSource.remmina),
      ),
      // A Remote Desktop file, only where this build offers RDP hosts.
      if (ref.watch(rdpOfferedProvider))
        ImportSourceCard(
          key: const ValueKey('file-source-rdp-file'),
          mark: 'RD',
          title: l10n.migrateRdpFileTitle,
          subtitle: l10n.migrateRdpFileDesc,
          onTap: () => file(_FileSource.rdpFile),
        ),
      ImportSourceCard(
        key: const ValueKey('file-source-termius'),
        mark: 'TM',
        title: 'Termius',
        subtitle: l10n.importTermiusDesc,
        onTap: () => file(_FileSource.termius),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-csv'),
        icon: LucideIcons.fileSpreadsheet,
        title: l10n.cloudImpCsv,
        subtitle: l10n.cloudImpCsvDesc,
        onTap: () => file(_FileSource.csv),
      ),
      ImportSourceCard(
        key: const ValueKey('file-source-zest'),
        icon: LucideIcons.fileKey,
        title: l10n.cloudImpZest,
        subtitle: l10n.cloudImpZestDesc,
        onTap: () => file(_FileSource.zest),
      ),
    ];
    final clouds = <Widget>[
      for (final p in CloudProvider.values)
        ImportSourceCard(
          key: ValueKey('cloud-source-${p.name}'),
          mark: cloudProviderMark(p),
          title: cloudProviderName(p),
          subtitle: cloudProviderBlurb(l10n, p),
          onTap: () => cloud(p),
        ),
    ];
    // Pasting, apart from the apps: quiet rows under a line.
    final pastes = <Widget>[
      _QuietSourceRow(
        key: const ValueKey('file-source-paste'),
        icon: LucideIcons.clipboardList,
        title: l10n.importPasteTitle,
        subtitle: l10n.importPasteDesc,
        onTap: () => file(_FileSource.paste),
      ),
      _QuietSourceRow(
        key: const ValueKey('file-source-share-link'),
        icon: LucideIcons.link,
        title: l10n.shareLinkPasteTitle,
        subtitle: l10n.shareLinkPasteDesc,
        onTap: () => file(_FileSource.shareLink),
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      // Three tiles to a row at the dialog's width, two where it is
      // narrower, one on a phone.
      final columns = importSourceColumns(box.maxWidth);
      final sheet = ZestSheetScope.of(context);
      final onClipboard = _clipboardLink?.share;
      final found = _found;
      final fileProblem = _fileProblem;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One action for a file, dropped or chosen, which works out what
          // the file is; choosing the app by hand stays below.
          _DropZone(
            reading: _readingFile,
            onFile: (path) => _readFile(() => readImportFile(path, rdp: ref.read(rdpOfferedProvider))),
            onChoose: _chooseFile,
          ),
          if (fileProblem != null) ...[
            const SizedBox(height: 8),
            _ErrorPanel(message: fileProblem.said, detail: '${fileProblem.cause}'),
          ],
          if (found != null) ...[
            const SizedBox(height: 8),
            _FoundFile(
              file: found,
              kindAs: _foundAs,
              onKind: (k) => setState(() => _foundAs = k),
              onClose: () => setState(() {
                _found = null;
                _foundAs = null;
              }),
              onImport: (kind) => Navigator.of(context).pop(ImportFromFile(file: found, kind: kind)),
              onOpenKeys: () {
                final navigator = Navigator.of(context);
                final outer = navigator.context;
                navigator.pop();
                openKeysPage(outer);
              },
            ),
          ],
          // First: a share link that is on the clipboard, its host to add
          // (after the confirmation every share link has).
          if (onClipboard != null) ...[
            const SizedBox(height: 20),
            ImportGroupLabel(l10n.shareLinkClipGroup),
            ImportSourceRow(
              key: const ValueKey('import-clipboard-share-link'),
              icon: LucideIcons.clipboardCheck,
              title: l10n.shareLinkClipAdd(Redactable.host(onClipboard.label).displayIn(ref)),
              subtitle: l10n.shareLinkClipAddDesc(Redactable.address(_shareAddress(onClipboard)).displayIn(ref)),
              onTap: () => Navigator.of(context).pop(ImportFromShareLink(reading: _clipboardLink)),
            ),
          ],
          const SizedBox(height: 22),
          ImportGroupLabel(l10n.migrateFromApps),
          const SizedBox(height: 4),
          _SourceGrid(columns: columns, children: apps),
          const SizedBox(height: 22),
          ImportGroupLabel(l10n.importFromCloud),
          const SizedBox(height: 4),
          _SourceGrid(columns: columns, children: clouds),
          Container(
            key: const ValueKey('import-pastes'),
            margin: const EdgeInsets.only(top: 18),
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
            child: columns > 1
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Expanded(child: pastes[0]), const SizedBox(width: 10), Expanded(child: pastes[1])],
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: pastes),
          ),
          // Last, on a phone: what is not here (a computer's footer says it).
          if (sheet) ...[
            const SizedBox(height: 14),
            _AskForSource(onTap: () => Navigator.of(context).pop(const ImportAskForSource())),
          ],
        ],
      );
    });
  }

  /// [share]'s address as written to connect to it: user@host:port, an
  /// IPv6 address in brackets.
  static String _shareAddress(ParsedConnectionShare share) {
    final user = share.user;
    return '${user == null ? '' : '$user@'}${hostWithPort(share.host, share.port)}';
  }

  Widget _connectBody(AppLocalizations l10n, CloudProvider provider) {
    final cert = _certificate;
    final fields = cloudFieldsOf(l10n, provider);
    final labels = _labelColumn(context, [l10n.cloudImpAccountName, for (final f in fields) f.label]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestField(
          key: const ValueKey('cloud-account-name'),
          label: l10n.cloudImpAccountName,
          labelWidth: labels,
          controller: _label,
          helperText: l10n.deskCloudAccountNameHelp(cloudProviderName(provider)),
          enabled: !_busy && cert == null,
        ),
        const SizedBox(height: 10),
        for (final f in fields) ...[
          ZestField(
            key: ValueKey('cloud-field-${f.key}'),
            label: f.label,
            labelWidth: labels,
            controller: _field(f.key),
            obscureText: f.secret,
            isMono: true,
            placeholder: f.placeholder,
            helperText: f.help,
            errorText: _fieldErrors[f.key],
            enabled: !_busy && cert == null,
            onChanged: (_) {
              if (_fieldErrors.remove(f.key) != null) setState(() {});
              if (f.key == CloudField.url && _pin != null) setState(() => _pin = null);
              // The trust line names what a Headscale server needs.
              if (f.key == CloudField.server) setState(() {});
            },
          ),
          const SizedBox(height: 10),
        ],
        // The trust line: where the token goes (here only), whether it is
        // kept (as the switch below says), and the least it needs.
        _Caption(
          [
            l10n.cloudImpTrustDevice,
            _keep ? l10n.cloudImpTrustKept : l10n.cloudImpTrustNotKept,
            provider == CloudProvider.tailscale && _field(CloudField.server).text.trim().isNotEmpty
                ? l10n.cloudImpTokenHeadscale
                : cloudTokenCaption(l10n, provider),
          ].join(' '),
          key: const ValueKey('cloud-trust'),
        ),
        const SizedBox(height: 6),
        _HowTo(
          open: _howTo,
          onToggle: () => setState(() => _howTo = !_howTo),
          steps: cloudHowTo(l10n, provider),
        ),
        const SizedBox(height: 12),
        _SwitchRow(
          key: const ValueKey('cloud-keep'),
          title: l10n.cloudImpKeep,
          subtitle: l10n.cloudImpKeepDesc,
          value: _keep,
          onChanged: _busy ? null : (v) => setState(() => _keep = v),
        ),
        if (cert != null) ...[
          const SizedBox(height: 12),
          _certificatePanel(l10n, cert),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorPanel(message: cloudErrorMessage(l10n, _error!.kind, provider), detail: _error!.detail),
        ],
      ],
    );
  }

  Widget _certificatePanel(AppLocalizations l10n, CloudCertificate cert) {
    final typed = _pastedFingerprint.text.trim();
    final matches = typed.isNotEmpty && !_fingerprintMismatch;
    return Container(
      key: const ValueKey('cloud-certificate'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZestTokens.statusWarning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.statusWarning.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(LucideIcons.shieldAlert, size: 16, color: ZestTokens.statusWarning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l10n.cloudImpCertTitle,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(l10n.cloudImpCertBody, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
          const SizedBox(height: 10),
          Text(l10n.cloudImpCertFingerprint, style: TextStyle(fontSize: 11, color: ZestTokens.textTertiary)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(cert.sha256,
                    key: const ValueKey('cloud-certificate-fingerprint'),
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.4, color: ZestTokens.textPrimary)),
              ),
              IconButton(
                tooltip: l10n.cloudImpCopy,
                icon: Icon(LucideIcons.copy, size: 15, color: ZestTokens.textTertiary),
                onPressed: () => Clipboard.setData(ClipboardData(text: cert.sha256)),
              ),
            ],
          ),
          if (cert.validUntil != null)
            Text(l10n.cloudImpCertValid(MaterialLocalizations.of(context).formatMediumDate(cert.validUntil!.toLocal())),
                style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
          const SizedBox(height: 10),
          ZestField(
            key: const ValueKey('cloud-certificate-paste'),
            label: l10n.cloudImpCertCompare,
            labelWidth: _labelColumn(context, [l10n.cloudImpCertCompare]),
            controller: _pastedFingerprint,
            isMono: true,
            maxLines: 2,
            placeholder: l10n.cloudImpCertPaste,
          ),
          if (typed.isNotEmpty) ...[
            const SizedBox(height: 6),
            ZestStatusPill(
              kind: matches ? ZestStatusKind.healthy : ZestStatusKind.critical,
              label: matches ? l10n.cloudImpCertMatch : l10n.cloudImpCertNoMatch,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chooseBody(AppLocalizations l10n, CloudProvider provider) {
    final name = cloudProviderName(provider);
    final selectable = [for (var i = 0; i < _rows.length; i++) if (_rows[i].selectable) i];
    final allOn = selectable.isNotEmpty && selectable.every(_ticked.contains);
    final anyPrivate = _machines.any((m) => m.privateAddress != null && m.publicAddress != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _machines.isEmpty ? l10n.cloudImpFoundNone(name) : l10n.cloudImpFound(_machines.length, name),
                style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
              ),
            ),
            if (selectable.isNotEmpty)
              ZestButton(
                key: const ValueKey('cloud-select-all'),
                label: allOn ? l10n.sshImportDeselectAll : l10n.sshImportSelectAll,
                variant: ZestButtonVariant.ghost,
                size: ZestButtonSize.medium,
                onPressed: () {
                  for (final i in selectable) {
                    _tick(i, !allOn);
                  }
                },
              ),
          ],
        ),
        if (anyPrivate) ...[
          const SizedBox(height: 4),
          _SwitchRow(
            key: const ValueKey('cloud-private'),
            title: l10n.cloudImpUsePrivate,
            subtitle: l10n.cloudImpUsePrivateDesc,
            value: _preferPrivate,
            onChanged: (v) async {
              setState(() => _preferPrivate = v);
              await _plan(_machines);
            },
          ),
        ],
        const SizedBox(height: 8),
        for (var i = 0; i < _rows.length; i++)
          _MachineRow(
            key: ValueKey('cloud-row-$i'),
            row: _rows[i],
            provider: provider,
            ticked: _ticked.contains(i),
            onChanged: _rows[i].selectable ? (v) => _tick(i, v) : null,
          ),
      ],
    );
  }

  Widget _destinationBody(AppLocalizations l10n, CloudProvider provider) {
    final hint = cloudSignInHint(l10n, provider);
    final labels = _labelColumn(context, [l10n.cloudImpSignIn, l10n.cloudImpGroup]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ImportGroupLabel(l10n.cloudImpWhere),
        for (final d in _destinations)
          ImportSourceTile(
            key: ValueKey('cloud-destination-${d.key}'),
            selected: d.key == _destination.key,
            title: d.isTree ? l10n.cloudImpTree : '${d.orchardName}, ${d.crateName}',
            subtitle: d.isTree ? l10n.cloudImpTreeDesc : l10n.cloudImpCrateDesc(d.crateName!),
            onTap: () => _pickDestination(d),
          ),
        const SizedBox(height: 12),
        // The app's select, drawn in the field's shell (a Material dropdown
        // sat in it, its value above the name's line).
        // The hint stands under the field, not in the shell,
        // so the menu hangs under the field itself.
        ZestSelect<String?>(
          key: ValueKey('cloud-identity-${_destination.key}'),
          value: _identityId,
          items: [
            ZestSelectItem(null, l10n.cloudImpAskWhenConnecting),
            for (final i in _identities)
              ZestSelectItem(
                i.id,
                '${Redactable.keyName(i.label).displayIn(ref)} (${Redactable.username(i.username).displayIn(ref)})',
              ),
          ],
          onChanged: (v) => setState(() => _identityId = v),
          frame: (value) => ZestField.custom(label: l10n.cloudImpSignIn, labelWidth: labels, child: value),
        ),
        if (hint != null && hint.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(hint, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textMuted)),
        ],
        const SizedBox(height: 10),
        ZestField(
          key: const ValueKey('cloud-group'),
          label: l10n.cloudImpGroup,
          labelWidth: labels,
          controller: _group,
          helperText: l10n.cloudImpGroupHelp,
        ),
        const SizedBox(height: 8),
        ImportCompatibilityOption(
          key: const ValueKey('cloud-compatibility'),
          value: _compatibility,
          onChanged: _busy ? null : (v) => setState(() => _compatibility = v),
        ),
        const SizedBox(height: 8),
        _Note(icon: LucideIcons.link, text: l10n.cloudImpLinkedNote(_label.text.trim())),
      ],
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

/// "Turn on Compatibility mode for these hosts", where hosts are imported: for
/// a file of old servers, all of them at once rather than host by host
/// afterwards (such as 42 end-of-life Linux hosts from SecureCRT, turned on
/// one by one). Off unless ticked, and said as not recommended, as in the host
/// editor.
class ImportCompatibilityOption extends StatelessWidget {
  const ImportCompatibilityOption({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final change = onChanged;
    return CheckboxListTile(
      value: value,
      onChanged: change == null ? null : (v) => change(v ?? false),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(l10n.csvImpCompatibility, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
      subtitle: Text(l10n.csvImpCompatibilityNote,
          style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary)),
    );
  }
}

/// Import a file, at the top of the first step (4.0): on
/// a computer a file dropped on it is read ("Drop a file here, or choose
/// one"), and Choose a file asks for one; ZestSSH works out what it is. A
/// phone, where nothing is dropped, has its button under what it does, 48
/// high.
class _DropZone extends StatefulWidget {
  const _DropZone({required this.reading, required this.onFile, required this.onChoose});

  /// A file is being read: the button turns while it is.
  final bool reading;
  final void Function(String path) onFile;
  final VoidCallback onChoose;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sheet = ZestSheetScope.of(context);
    // A computer's dialog; never a phone's sheet, where nothing is dropped.
    final drops = isDesktopPlatform && !sheet;
    final over = _over;
    final button = ZestButton(
      key: const ValueKey('import-file'),
      label: l10n.importChooseFile,
      icon: LucideIcons.file,
      variant: ZestButtonVariant.primary,
      size: ZestButtonSize.large,
      isLoading: widget.reading,
      onPressed: widget.onChoose,
    );
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          drops ? l10n.importDropTitle : l10n.importFileAction,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(l10n.importDropDesc, style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textTertiary)),
      ],
    );
    final tile = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: over ? ZestTokens.brandIconBg : ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(LucideIcons.upload, size: 20, color: over ? ZestTokens.brandInk : ZestTokens.textSecondary),
    );
    final zone = LayoutBuilder(builder: (context, box) {
      // Its button beside the words where there is room, under them on a
      // phone and in a narrow window.
      final wide = !sheet && box.maxWidth >= 560;
      return DecoratedBox(
        key: const ValueKey('import-drop'),
        decoration: BoxDecoration(
          color: over ? ZestTokens.brand.withValues(alpha: 0.08) : ZestTokens.surfaceSunken,
          borderRadius: BorderRadius.circular(12),
        ),
        child: WorkspaceDashedBox(
          radius: 12,
          color: over ? ZestTokens.brand : ZestTokens.borderStrong,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: wide
              ? Row(
                  children: [
                    tile,
                    const SizedBox(width: 16),
                    Expanded(child: words),
                    const SizedBox(width: 16),
                    button,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [tile, const SizedBox(width: 14), Expanded(child: words)],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(height: sheet ? 48 : null, child: button),
                  ],
                ),
        ),
      );
    });
    if (!drops) return zone;
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (details) {
        setState(() => _over = false);
        final path = details.files.map((f) => f.path).where((p) => p.isNotEmpty).firstOrNull;
        if (path != null) widget.onFile(path);
      },
      child: zone,
    );
  }
}

/// How many source tiles stand in a row at [width]: three at the dialog's
/// width on a computer, two where it is narrower, one on a phone.
int importSourceColumns(double width) => width >= 720 ? 3 : (width >= 460 ? 2 : 1);

/// [children] in rows of [columns], each row's tiles as tall as its tallest.
class _SourceGrid extends StatelessWidget {
  const _SourceGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 8), child],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i += columns) ...[
          if (i > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < columns; j++) ...[
                  if (j > 0) const SizedBox(width: 10),
                  Expanded(child: i + j < children.length ? children[i + j] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Each product's own muted colour for its monogram, from the app's label
/// palette, so that no two in a grid look alike (every one was the same
/// grey, and PuTTY, AWS and Azure looked alike). Tailscale keeps the grey of
/// its own mark; a file format has a plain icon instead.
Color? importMarkHue(String mark) => switch (mark) {
      'PT' || 'DO' => AppColors.labelPalette[4],
      'MX' || 'AZ' => AppColors.labelPalette[7],
      'CRT' || 'PVE' => AppColors.labelPalette[5],
      'FZ' => AppColors.labelPalette[6],
      'WS' => AppColors.labelPalette[3],
      'TM' || 'AWS' => AppColors.labelPalette[1],
      'HZ' => AppColors.labelPalette[0],
      _ => null,
    };

/// One source of hosts as a tile (4.0): a product's
/// monogram ([mark]) in its own muted colour ([importMarkHue]), or a file
/// format's plain [icon]; its name; what it takes, in up to three lines. The
/// whole tile is the target, at least 64 tall, and takes the keyboard (its
/// edge in the accent while it has it).
class ImportSourceCard extends StatefulWidget {
  const ImportSourceCard({super.key, this.icon, this.mark, required this.title, required this.subtitle, required this.onTap});

  final IconData? icon;
  final String? mark;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<ImportSourceCard> createState() => _ImportSourceCardState();
}

class _ImportSourceCardState extends State<ImportSourceCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final mark = widget.mark;
    final hue = mark == null ? null : importMarkHue(mark);
    final face = ZestTokens.surfaceElevated;
    final tileColor = hue == null ? ZestTokens.surfaceChip : Color.alphaBlend(hue.withValues(alpha: 0.16), face);
    final ink = hue == null ? ZestTokens.textSecondary : ZestColors.inkOn(hue, tileColor);
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: face,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: _focused ? ZestTokens.brand : ZestTokens.border, width: _focused ? 1.5 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (on) => setState(() => _focused = on),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: ZestSheetScope.of(context) ? 64 : 80),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: tileColor, borderRadius: BorderRadius.circular(10)),
                      child: mark == null
                          ? Icon(widget.icon, size: 18, color: ink)
                          // A picture of the product: its name is said beside it.
                          : Text(mark,
                              semanticsLabel: '',
                              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, fontWeight: FontWeight.w700, color: ink)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary)),
                          const SizedBox(height: 2),
                          Text(widget.subtitle,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textTertiary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paste a list, Paste a share link: a quiet row (its icon, its name, what it
/// takes, a chevron), at least 48 tall, the whole row the target.
class _QuietSourceRow extends StatelessWidget {
  const _QuietSourceRow({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: ZestTokens.textFaint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, height: 1.3, color: ZestTokens.textSecondary)),
                          Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textTertiary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(rtl ? LucideIcons.chevronLeft : LucideIcons.chevronRight, size: 16, color: ZestTokens.textPlaceholder),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Need to import something else? Let us know": the link closes Import
/// hosts for a suggestion.
class _AskForSource extends StatelessWidget {
  const _AskForSource({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Text(l10n.migrateAskTitle, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
        Semantics(
          link: true,
          child: InkWell(
            key: const ValueKey('import-ask-source'),
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Text(l10n.migrateAskLink,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
            ),
          ),
        ),
      ],
    );
  }
}

/// What Import a file found: "Looks like a ZestSSH backup. Import it?", the
/// file's name, Import it, and a way to say it is something else. Where it
/// could not tell, it asks; where it found a private key, nothing else reads
/// it. Nothing imports a public key or a known_hosts file: it says so, and
/// what to do.
class _FoundFile extends ConsumerWidget {
  const _FoundFile({
    required this.file,
    required this.kindAs,
    required this.onKind,
    required this.onClose,
    required this.onImport,
    required this.onOpenKeys,
  });

  final ImportFile file;
  final ImportKind? kindAs;
  final ValueChanged<ImportKind> onKind;
  final VoidCallback onClose;
  final ValueChanged<ImportKind> onImport;
  final VoidCallback onOpenKeys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final kind = kindAs ?? file.kind;
    final unknown = kind == ImportKind.unknown;
    return Container(
      key: const ValueKey('import-found'),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 6, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: unknown ? ZestTokens.statusWarning.withValues(alpha: 0.5) : ZestTokens.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(unknown ? LucideIcons.fileQuestion : LucideIcons.fileCheck,
                    size: 16, color: unknown ? ZestTokens.statusWarning : ZestTokens.textSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      importFoundWords(kind, l10n),
                      key: const ValueKey('import-found-words'),
                      style: TextStyle(fontSize: 13, height: 1.45, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                    ),
                    if (unknown) ...[
                      const SizedBox(height: 2),
                      Text(l10n.importFoundUnknownBody,
                          style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
                    ],
                    const SizedBox(height: 2),
                    RedactedText(
                      Redactable.path(file.name),
                      key: const ValueKey('import-found-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestTokens.textTertiary),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('import-found-close'),
                tooltip: l10n.close,
                iconSize: 15,
                // A mouse's 32 square at least (compact, it was 28).
                visualDensity: VisualDensity.standard,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(LucideIcons.x, color: ZestTokens.textTertiary),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 26, end: 6),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (kind == ImportKind.publicKey)
                  ZestButton(
                    key: const ValueKey('import-found-keys'),
                    label: l10n.importOpenKeys,
                    icon: LucideIcons.keyRound,
                    variant: ZestButtonVariant.primary,
                    onPressed: onOpenKeys,
                  )
                else if (kind != ImportKind.knownHosts)
                  ZestButton(
                    key: const ValueKey('import-found-go'),
                    label: l10n.importItAction,
                    icon: LucideIcons.download,
                    variant: ZestButtonVariant.primary,
                    onPressed: importCanTake(file, kind) ? () => onImport(kind) : null,
                  ),
                // What is only a private key, nothing else reads.
                if (file.kind != ImportKind.privateKey || importCanReadAnyway(file))
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: ZestSelect<ImportKind>(
                      key: const ValueKey('import-found-as'),
                      value: kindAs,
                      hint: l10n.importNotThat,
                      onChanged: onKind,
                      items: [
                        for (final k in kImportKindsToChoose) ZestSelectItem(k, importKindName(k, l10n)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "1 Source, 2 Connect, 3 Choose hosts, 4 Destination": done steps are
/// ticked, the current one is filled.
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.names, required this.current});

  final List<String> names;
  final int current;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      // Where every step's name does not fit on one line, the one in hand
      // by its number, over a bar of every step (the row wrapped and left a
      // step alone on a line of its own).
      builder: (context, box) => box.maxWidth < 520 ? _compact(context) : _row(context),
    );
  }

  Widget _compact(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('cloud-steps-compact'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.deskCloudStepOf(current + 1, names.length, names[current]),
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < names.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: i <= current ? ZestTokens.brand : ZestTokens.borderStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _row(BuildContext context) {
    final brand = ZestTokens.brand;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (var i = 0; i < names.length; i++) ...[
          // One thing to a screen reader: "Step 1 of 3 · Source", the one in
          // hand picked (it read "1", "Source", "2" as separate lines).
          Semantics(
            label: AppLocalizations.of(context)!.deskCloudStepOf(i + 1, names.length, names[i]),
            selected: i == current,
            excludeSemantics: true,
            child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == current ? brand : Colors.transparent,
                  border: Border.all(
                    color: i < current ? ZestTokens.statusHealthy : (i == current ? brand : ZestTokens.borderStrong),
                  ),
                ),
                child: i < current
                    ? Icon(LucideIcons.check, size: 11, color: ZestTokens.statusHealthy)
                    : Text('${i + 1}',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: i == current ? const Color(0xFF1A0D04) : ZestTokens.textTertiary)),
              ),
              const SizedBox(width: 6),
              Text(names[i],
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
                      color: i == current ? ZestTokens.textPrimary : ZestTokens.textTertiary)),
            ],
          ),
          ),
          if (i < names.length - 1) Container(width: 18, height: 1, color: ZestTokens.borderStrong),
        ],
      ],
    );
  }
}

/// A group's name over its choices ("FILES").
class ImportGroupLabel extends StatelessWidget {
  const ImportGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ZestSectionHeader(label: text),
      );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textMuted));
}

/// A radio-style choice: the whole tile is the target.
class ImportSourceTile extends StatelessWidget {
  const ImportSourceTile({super.key, required this.selected, required this.title, required this.subtitle, this.mark, required this.onTap});

  final bool selected;
  final String title;
  final String subtitle;
  final String? mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.v3AccentPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.07) : ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? accent.withValues(alpha: 0.5) : ZestTokens.borderSubtle, width: selected ? 1 : 0.5),
            ),
            child: Row(
              children: [
                Icon(selected ? LucideIcons.circleDot : LucideIcons.circle,
                    size: 16, color: selected ? ZestTokens.brandInk : ZestTokens.textTertiary),
                const SizedBox(width: 10),
                if (mark != null) ...[
                  Container(
                    width: 30,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ZestTokens.surfaceChip,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: ZestTokens.borderSubtle),
                    ),
                    child: Text(mark!,
                        semanticsLabel: '',
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 9.5, fontWeight: FontWeight.w700, color: ZestTokens.textSecondary)),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One source of hosts: a glyph for a format ([icon]) or a monogram for a
/// product ([mark]), its name, one line of what it takes, and a chevron. The
/// whole row is the target, at least 52 tall, and takes the keyboard.
class ImportSourceRow extends StatelessWidget {
  const ImportSourceRow({super.key, this.icon, this.mark, required this.title, required this.subtitle, required this.onTap});

  final IconData? icon;
  final String? mark;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: ZestTokens.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestTokens.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    // Glyph or monogram, one tile a step above the card.
                    decoration: BoxDecoration(
                      color: ZestTokens.surfaceChip,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ZestTokens.borderSubtle),
                    ),
                    child: icon != null
                        ? Icon(icon, size: 16, color: ZestTokens.textSecondary)
                        : Text(mark ?? '',
                            semanticsLabel: '',
                            style: TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: ZestTokens.textSecondary)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(LucideIcons.chevronRight, size: 15, color: ZestTokens.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({super.key, required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZestSwitch(value: value, onChanged: onChanged),
        ],
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: ZestTokens.textTertiary),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary))),
          ],
        ),
      );
}

/// What went wrong, in words, with its details to copy.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.detail});
  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('cloud-error'),
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
          if (detail.isNotEmpty)
            Align(alignment: Alignment.centerRight, child: CopyDetailsButton(detail: detail, label: l10n.desktopShellCopyDetails)),
        ],
      ),
    );
  }
}

/// "How to make one": the provider's steps, each with what to copy.
class _HowTo extends StatelessWidget {
  const _HowTo({required this.open, required this.onToggle, required this.steps});
  final bool open;
  final VoidCallback onToggle;
  final List<CloudHowToStep> steps;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('cloud-how-to'),
            onPressed: onToggle,
            icon: Icon(open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14),
            label: Text(l10n.cloudImpHowTo),
          ),
        ),
        if (open)
          for (final s in steps) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Text(s.text, style: TextStyle(fontSize: 12, height: 1.5, color: ZestTokens.textSecondary)),
            ),
            if (s.copy != null) ...[
              _CopyBlock(text: s.copy!),
              const SizedBox(height: 8),
            ],
          ],
      ],
    );
  }
}

class _CopyBlock extends StatelessWidget {
  const _CopyBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.borderSubtle, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(text,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.45, color: ZestTokens.textPrimary)),
            ),
          ),
          IconButton(
            tooltip: l10n.cloudImpCopy,
            icon: Icon(LucideIcons.copy, size: 14, color: ZestTokens.textTertiary),
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
        ],
      ),
    );
  }
}

/// One machine: tick, name, address, where, status.
class _MachineRow extends ConsumerWidget {
  const _MachineRow({super.key, required this.row, required this.provider, required this.ticked, required this.onChanged});

  final CloudRow row;
  final CloudProvider provider;
  final bool ticked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final m = row.machine;
    final name = m?.name ?? row.existing?.label ?? '';
    final address = row.address ?? row.existing?.host ?? '';
    final where = [
      if (m != null && m.where.isNotEmpty) m.where,
      if (m != null && m.tags.isNotEmpty) m.tags.first,
      if (m != null && !m.running) l10n.cloudImpStopped,
    ].join(', ');
    final (kind, label, tip) = switch (row.status) {
      CloudRowStatus.fresh => (ZestStatusKind.healthy, l10n.cloudImpStNew, null),
      CloudRowStatus.here => (ZestStatusKind.neutral, l10n.cloudImpStHere, l10n.cloudImpStHereTip),
      CloudRowStatus.imported => (ZestStatusKind.neutral, l10n.cloudImpStImported, null),
      CloudRowStatus.changed => (ZestStatusKind.neutral, l10n.cloudImpStChanged, l10n.cloudImpStChangedTip(cloudProviderName(provider))),
      CloudRowStatus.noSsh => (ZestStatusKind.stale, l10n.cloudImpStNoSsh, l10n.cloudImpStNoSshTip),
      CloudRowStatus.noAddress => (ZestStatusKind.stale, l10n.cloudImpStNoAddress, null),
      CloudRowStatus.gone => (ZestStatusKind.warning, l10n.cloudImpStGone, l10n.cloudImpStGoneTip),
    };
    final pill = ZestStatusPill(
      kind: kind,
      label: label,
      icon: row.status == CloudRowStatus.changed ? LucideIcons.refreshCw : null,
    );
    final dim = onChanged == null && row.status != CloudRowStatus.gone;
    return Opacity(
      opacity: dim ? 0.6 : 1,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!ticked),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
          decoration: BoxDecoration(
            color: ticked ? ZestTokens.textPrimary.withValues(alpha: 0.04) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ZestTokens.borderSubtle),
          ),
          child: LayoutBuilder(builder: (context, box) {
            // A row that cannot be chosen has its box too, unticked and
            // off, so every row starts at the same place.
            final tick = SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                value: onChanged == null ? false : ticked,
                activeColor: ZestTokens.brand,
                checkColor: ZestTokens.onBrand,
                side: BorderSide(color: onChanged == null ? ZestTokens.border : ZestTokens.borderStrong),
                onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
              ),
            );
            final nameText = RedactedText(Redactable.host(name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary));
            final addressText = RedactedText(Redactable.address(address),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textSecondary));
            final whereText = Text(where,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestTokens.textTertiary));
            final status = tip == null ? pill : Tooltip(message: tip, child: pill);
            // A phone: name over address and where, the status beside.
            if (box.maxWidth < 560) {
              return Row(
                children: [
                  tick,
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        nameText,
                        const SizedBox(height: 2),
                        Row(children: [
                          if (address.isNotEmpty) Flexible(child: addressText),
                          if (address.isNotEmpty && where.isNotEmpty) const SizedBox(width: 8),
                          if (where.isNotEmpty) Flexible(child: whereText),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  status,
                ],
              );
            }
            // Fixed columns: the address and where start at the same place
            // on every row, whatever its status says.
            return Row(
              children: [
                tick,
                const SizedBox(width: 6),
                Expanded(flex: 5, child: nameText),
                const SizedBox(width: 12),
                SizedBox(width: 132, child: Align(alignment: Alignment.centerLeft, child: addressText)),
                const SizedBox(width: 12),
                Expanded(flex: 6, child: Align(alignment: Alignment.centerLeft, child: whereText)),
                const SizedBox(width: 12),
                // (A longer word in another language is made smaller to fit.)
                SizedBox(
                  width: 136,
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: status),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
