// Prometheus monitor data-source configuration, extracted from the main
// settings screen so monitor configuration lives WITH the Server Monitor
// (settings decluttering pass). Pure relocation: the sheet logic is unchanged.

import 'dart:io';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/prometheus_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// Opens the full Prometheus configuration: the app's dialog (3.4), a
/// phone's sheet, its fields in the body, Test connection the footer's side
/// link, then Cancel and Save (a sheet of its own before, with Test
/// connection in its header and its buttons under the fields).
void showPrometheusConfigSheet(BuildContext context) {
  showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: const PrometheusConfigSheet(),
  );
}


/// Compact "Data source" - the monitor-side home for choosing SSH vs
/// Prometheus and reaching the full Prometheus configuration. Replaces the two
/// tiles that used to sit in the main settings list. The app's dialog (3.4),
/// a phone's sheet: the two sources picked by a dot radio, which takes effect
/// at once, the Prometheus settings the footer's side link, and Done (a
/// sheet of its own before, on a computer too).
void showMonitorDataSourceSheet(BuildContext context) {
  showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: const MonitorDataSourceSheet(),
  );
}

class MonitorDataSourceSheet extends ConsumerWidget {
  const MonitorDataSourceSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final source = ref.watch(monitorDataSourceProvider);
    final settings = ref.read(settingsServiceProvider);

    void setSource(String v) {
      ref.read(settingsServiceProvider).setMonitorDataSource(v);
      ref.invalidate(monitorDataSourceProvider);
    }

    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.database,
      title: l10n.monitorDataSource,
      subtitle: l10n.monitorSettingsDataSourceDesc,
      body: RadioGroup<String>(
        groupValue: source,
        onChanged: (v) {
          if (v != null) setSource(v);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioListTile<String>(
              key: const ValueKey('monitor-source-ssh'),
              value: 'ssh',
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.monitorDataSourceSsh),
            ),
            RadioListTile<String>(
              key: const ValueKey('monitor-source-prometheus'),
              value: 'prometheus',
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.monitorDataSourcePrometheus),
              // Where it reads from, once it is the source.
              subtitle: source == 'prometheus'
                  ? Text(
                      settings.prometheusUrl ?? l10n.monitorPrometheusUrlHint,
                      style: TextStyle(color: settings.prometheusUrl != null ? null : AppColors.onSurfaceDim),
                    )
                  : null,
            ),
          ],
        ),
      ),
      // Its settings, in a dialog of their own once this one has closed.
      tertiaryKey: const ValueKey('monitor-source-prometheus-settings'),
      tertiaryAction: source == 'prometheus'
          ? (
              label: l10n.monitorSettingsPrometheusConfig,
              onPressed: () {
                Navigator.pop(context);
                showPrometheusConfigSheet(context);
              },
            )
          : null,
      primaryKey: const ValueKey('monitor-source-done'),
      primaryAction: (label: l10n.done, icon: null, onPressed: () => Navigator.pop(context)),
    );
  }
}

class PrometheusConfigSheet extends ConsumerStatefulWidget {
  const PrometheusConfigSheet({super.key});

  @override
  ConsumerState<PrometheusConfigSheet> createState() =>
      PrometheusConfigSheetState();
}

class PrometheusConfigSheetState
    extends ConsumerState<PrometheusConfigSheet> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _bearerCtrl;
  late final TextEditingController _basicUserCtrl;
  late final TextEditingController _basicPassCtrl;
  late final TextEditingController _customKeyCtrl;
  late final TextEditingController _customValueCtrl;
  late final TextEditingController _certPasswordCtrl;

  late PrometheusAuthType _authType;
  late bool _verifySsl;

  bool _hasCaCert = false;
  bool _hasClientCert = false;
  bool _isTesting = false;
  bool _isSaving = false;
  bool _tlsExpanded = false;
  bool _authExpanded = false;

  /// The authentication section, brought into view as it opens.
  final _authKey = GlobalKey();

  // Password visibility toggles
  bool _showCertPassword = false;
  bool _showBearerToken = false;
  bool _showBasicPassword = false;
  bool _showCustomValue = false;

  // Inline test result banner state
  String? _testResultMessage;
  bool _testResultIsError = false;

  /// What failed behind [_testResultMessage], for Copy details.
  Object? _testResultCause;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsServiceProvider);
    _urlCtrl = TextEditingController(text: settings.prometheusUrl ?? '');
    _bearerCtrl = TextEditingController();
    _basicUserCtrl = TextEditingController();
    _basicPassCtrl = TextEditingController();
    _customKeyCtrl =
        TextEditingController(text: settings.prometheusCustomHeaderKey ?? '');
    _customValueCtrl = TextEditingController();
    _certPasswordCtrl = TextEditingController();

    _authType = PrometheusAuthType.fromKey(settings.prometheusAuthType);
    _verifySsl = settings.prometheusVerifySsl;

    _loadSecureFields();
  }

  Future<void> _loadSecureFields() async {
    final secure = ref.read(prometheusSecureSettingsProvider);
    final results = await Future.wait([
      secure.hasCaPem(),
      secure.hasClientCert(),
      secure.getBearerToken(),
      secure.getBasicAuthUser(),
      secure.getBasicAuthPassword(),
      secure.getCustomHeaderValue(),
      secure.getClientCertPassword(),
    ]);
    if (!mounted) return;
    setState(() {
      _hasCaCert = results[0] as bool;
      _hasClientCert = results[1] as bool;
      _bearerCtrl.text = (results[2] as String?) ?? '';
      _basicUserCtrl.text = (results[3] as String?) ?? '';
      _basicPassCtrl.text = (results[4] as String?) ?? '';
      _customValueCtrl.text = (results[5] as String?) ?? '';
      _certPasswordCtrl.text = (results[6] as String?) ?? '';
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _bearerCtrl.dispose();
    _basicUserCtrl.dispose();
    _basicPassCtrl.dispose();
    _customKeyCtrl.dispose();
    _customValueCtrl.dispose();
    _certPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAll() async {
    setState(() => _isSaving = true);
    try {
      final settings = ref.read(settingsServiceProvider);
      final secure = ref.read(prometheusSecureSettingsProvider);

      // Non-sensitive → SharedPreferences
      final url = _urlCtrl.text.trim();
      await settings.setPrometheusUrl(url.isEmpty ? null : url);
      await settings.setPrometheusAuthType(_authType.key);
      await settings.setPrometheusVerifySsl(_verifySsl);
      await settings.setPrometheusCustomHeaderKey(
          _customKeyCtrl.text.trim().isEmpty
              ? null
              : _customKeyCtrl.text.trim());

      // Sensitive → SecureStorage
      await secure.setBearerToken(_bearerCtrl.text.trim().isEmpty
          ? null
          : _bearerCtrl.text.trim());
      await secure.setBasicAuthUser(_basicUserCtrl.text.trim().isEmpty
          ? null
          : _basicUserCtrl.text.trim());
      await secure.setBasicAuthPassword(_basicPassCtrl.text.trim().isEmpty
          ? null
          : _basicPassCtrl.text.trim());
      await secure.setCustomHeaderValue(_customValueCtrl.text.trim().isEmpty
          ? null
          : _customValueCtrl.text.trim());
      await secure.setClientCertPassword(_certPasswordCtrl.text.trim().isEmpty
          ? null
          : _certPasswordCtrl.text.trim());

      // Invalidate providers so they rebuild with new config
      ref.invalidate(prometheusConfigCacheProvider);
      ref.invalidate(prometheusServiceProvider);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResultMessage = null;
    });
    final l10n = AppLocalizations.of(context)!;

    // Save first so the service uses current values
    await _saveAll();

    // Wait for the async cache provider to fully resolve after invalidation
    // (it reads from secure storage which is async)
    try {
      await ref.read(prometheusConfigCacheProvider.future);
    } catch (_) {
      // Cache read failed - continue, service will be null
    }

    final prometheus = ref.read(prometheusServiceProvider);
    if (prometheus == null) {
      if (!mounted) return;
      final url = _urlCtrl.text.trim();
      _showTestResult(
          l10n.monitorPrometheusTestFailed(url.isEmpty
              ? l10n.prometheusConfigNoUrlConfigured
              : l10n.prometheusConfigServiceNotReady),
          isError: true);
      setState(() => _isTesting = false);
      return;
    }

    try {
      final (result, detail) = await prometheus.testConnection();
      if (!mounted) return;

      switch (result) {
        case PrometheusTestResult.success:
          String? found;
          try {
            final targets = await prometheus.discoverTargets();
            found = l10n.monitorPrometheusTargetsFound(targets.length);
          } catch (_) {
            // Target discovery is best-effort
          }
          if (!mounted) return;
          _showTestResult(
            found == null
                ? l10n.monitorPrometheusTestSuccess
                : l10n.monitorPrometheusConnectedFound(l10n.monitorPrometheusTestSuccess, found),
            isError: false,
          );
          break;
        case PrometheusTestResult.caNotTrusted:
          _showTestResult(l10n.monitorPrometheusTestCaNotTrusted,
              isError: true);
          break;
        case PrometheusTestResult.clientCertRejected:
          _showTestResult(l10n.monitorPrometheusTestClientCertRejected,
              isError: true);
          break;
        case PrometheusTestResult.clientCertUnreadable:
          _showTestResult(l10n.monitorPromClientCertUnreadable,
              isError: true);
          break;
        case PrometheusTestResult.authFailed:
          _showTestResult(
              l10n.monitorPrometheusTestAuthFailed(detail ?? '401/403'),
              isError: true);
          break;
        case PrometheusTestResult.unreachable:
          _showTestResult(l10n.monitorPrometheusTestUnreachable,
              isError: true);
          break;
        case PrometheusTestResult.unknownError:
          _showTestResult(
              l10n.monitorPrometheusTestFailed(
                  detail ?? l10n.prometheusConfigUnknownError),
              isError: true);
          break;
      }
    } catch (e) {
      if (!mounted) return;
      _showTestResult(l10n.monitorPrometheusTestNotDone, isError: true, cause: e);
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  void _showTestResult(String message, {required bool isError, Object? cause}) {
    if (!mounted) return;
    setState(() {
      _testResultMessage = message;
      _testResultIsError = isError;
      _testResultCause = cause;
    });
    // Auto-dismiss after 10 seconds
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && _testResultMessage == message) {
        setState(() => _testResultMessage = null);
      }
    });
  }

  Future<void> _importCaCert() async {
    final l10n = AppLocalizations.of(context)!;
    // From a file (the question's first answer) or pasted (its other);
    // closed without either (Escape, a tap beside it), neither.
    final fromFile = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.monitorPrometheusCaCert,
      body: l10n.monitorPrometheusCaCertDesc,
      confirmLabel: l10n.monitorPrometheusCaCertImport,
      cancelLabel: l10n.monitorPrometheusCaCertPaste,
    );
    if (fromFile == null || !mounted) return;

    if (fromFile) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final file = File(result.files.first.path!);
      final pem = await file.readAsString();
      final secure = ref.read(prometheusSecureSettingsProvider);
      await secure.setCaPem(pem);
      if (mounted) setState(() => _hasCaCert = true);
    } else {
      // Paste dialog
      final pasteCtrl = TextEditingController();
      // The shell (the dialog rules of 3.4), with its field of several lines.
      // In the settings' place, which come back as they were (rule 4 of the
      // dialog rules, 3.4: no dialog over a dialog).
      final pem = await showZestInPlace<String>(
        context: context,
        size: ZestModalSize.standard,
        builder: (ctx) => ZestDialogShell(
            size: ZestModalSize.standard,
            tone: ZestDialogTone.neutral,
            icon: LucideIcons.clipboardPaste,
            title: l10n.monitorPrometheusCaCertPaste,
            body: TextField(
              key: const ValueKey('prometheus-ca-paste'),
              controller: pasteCtrl,
              autofocus: true,
              minLines: 8,
              maxLines: 8,
              // The app's own monospace font ('monospace' names no font on
              // Windows, macOS or iOS: a pasted certificate drew proportional).
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '-----BEGIN CERTIFICATE-----\n...',
                border: OutlineInputBorder(),
              ),
            ),
            secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(ctx)),
            primaryAction: (label: l10n.save, icon: null, onPressed: () => zestDialogPop(ctx, pasteCtrl.text)),
          ),
      );
      if (pem != null && pem.trim().isNotEmpty) {
        final secure = ref.read(prometheusSecureSettingsProvider);
        await secure.setCaPem(pem.trim());
        if (mounted) setState(() => _hasCaCert = true);
      }
    }
    ref.invalidate(prometheusConfigCacheProvider);
  }

  Future<void> _importClientCert() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = File(result.files.first.path!);
    final bytes = await file.readAsBytes();
    final secure = ref.read(prometheusSecureSettingsProvider);
    await secure.setClientCertP12Bytes(bytes);
    ref.invalidate(prometheusConfigCacheProvider);
    if (mounted) setState(() => _hasClientCert = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.plug,
      title: l10n.monitorSettingsPrometheusConfig,
      // Test connection: a side option, the footer's link (it sat in the
      // header); while it runs, the line under the fields says so.
      tertiaryKey: const ValueKey('prometheus-test'),
      tertiaryAction: (label: l10n.monitorPrometheusTestConnection, onPressed: _isTesting ? null : _testConnection),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryKey: const ValueKey('prometheus-save'),
      primaryAction: (
        label: l10n.save,
        icon: null,
        onPressed: _isSaving
            ? null
            : () async {
                await _saveAll();
                if (context.mounted) Navigator.pop(context);
              },
      ),
      body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isTesting)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                // What the test found: a line in its meaning's colour (red
                // or green), not a tinted tile.
                if (_testResultMessage != null)
                  Padding(
                    key: const ValueKey('prometheus-test-result'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _testResultIsError
                              ? LucideIcons.alertCircle
                              : LucideIcons.checkCircle2,
                          color: _testResultIsError
                              ? AppColors.error
                              : AppColors.success,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          // A failure detail can quote the endpoint host.
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RedactedText(
                                Redactable.freeText(_testResultMessage!),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: _testResultIsError ? AppColors.error : AppColors.success,
                                ),
                              ),
                              if (_testResultCause case final why?)
                                CopyDetailsButton(
                                  detail: ErrorReport.build(
                                      what: _testResultMessage!, where: 'Testing a Prometheus connection', error: why),
                                ),
                            ],
                          ),
                        ),
                        Tooltip(message: AppLocalizations.of(context)!.close, child: GestureDetector(
                          onTap: () =>
                              setState(() => _testResultMessage = null),
                          child: Icon(LucideIcons.x,
                              size: 16, color: AppColors.textSecondary),
                        )),
                      ],
                    ),
                  ),
                // ── URL ─────────────────────────────────────────
                // The endpoint host and the DNS server are identifiers:
                // while recording they render masked and read-only.
                RecordingMaskedFormField(
                  controller: _urlCtrl,
                  mask: maskEndpointUrl,
                  decoration: InputDecoration(
                    labelText: l10n.monitorPrometheusUrl,
                    hintText: l10n.monitorPrometheusUrlHint,
                    prefixIcon: const Icon(LucideIcons.link),
                  ),
                  child: TextField(
                    controller: _urlCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.monitorPrometheusUrl,
                      hintText: l10n.monitorPrometheusUrlHint,
                      prefixIcon: const Icon(LucideIcons.link),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(height: 20),

                // ── TLS Settings (expandable) ───────────────────
                _buildExpansionTile(
                  icon: LucideIcons.lock,
                  title: l10n.monitorPrometheusTlsSettings,
                  expanded: _tlsExpanded,
                  onToggle: () =>
                      setState(() => _tlsExpanded = !_tlsExpanded),
                  children: [
                    // Scope disclaimer: a note, in the text's colour (it was
                    // an orange tile).
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(LucideIcons.info, size: 16, color: AppColors.v3TextSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.monitorPrometheusTlsScopeNote,
                              style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Custom CA Certificate
                    _buildCertRow(
                      label: l10n.monitorPrometheusCaCert,
                      description: l10n.monitorPrometheusCaCertDesc,
                      isLoaded: _hasCaCert,
                      loadedText: l10n.monitorPrometheusCaCertLoaded,
                      importText: l10n.monitorPrometheusCaCertImport,
                      onImport: _importCaCert,
                      onClear: () async {
                        final secure = ref
                            .read(prometheusSecureSettingsProvider);
                        await secure.setCaPem(null);
                        ref
                            .invalidate(prometheusConfigCacheProvider);
                        if (mounted) setState(() => _hasCaCert = false);
                      },
                    ),
                    const SizedBox(height: 16),

                    // Client Certificate (mTLS)
                    _buildCertRow(
                      label: l10n.monitorPrometheusClientCert,
                      description: l10n.monitorPrometheusClientCertDesc,
                      isLoaded: _hasClientCert,
                      loadedText: l10n.monitorPrometheusClientCertLoaded,
                      importText: l10n.monitorPrometheusClientCertImport,
                      onImport: _importClientCert,
                      onClear: () async {
                        final secure = ref
                            .read(prometheusSecureSettingsProvider);
                        await secure.setClientCertP12Bytes(null);
                        await secure.setClientCertPassword(null);
                        ref
                            .invalidate(prometheusConfigCacheProvider);
                        if (mounted) {
                          setState(() => _hasClientCert = false);
                          _certPasswordCtrl.clear();
                        }
                      },
                    ),

                    // Client cert password (shown only if cert loaded)
                    if (_hasClientCert) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _certPasswordCtrl,
                        decoration: InputDecoration(
                          labelText:
                              l10n.monitorPrometheusClientCertPassword,
                          prefixIcon: const Icon(LucideIcons.keyRound),
                          suffixIcon: IconButton(
                            tooltip: _showCertPassword ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                            icon: Icon(_showCertPassword
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye),
                            onPressed: () => setState(
                                () => _showCertPassword = !_showCertPassword),
                          ),
                        ),
                        obscureText: !_showCertPassword,
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Verify SSL toggle
                    SwitchListTile(
                      title: Text(l10n.monitorPrometheusVerifySsl),
                      subtitle:
                          Text(l10n.monitorPrometheusVerifySslDesc,
                              style: const TextStyle(fontSize: 12)),
                      value: _verifySsl,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (v) => setState(() => _verifySsl = v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // ── Authentication (expandable) ─────────────────
                _buildExpansionTile(
                  key: _authKey,
                  icon: LucideIcons.shield,
                  title: l10n.monitorPrometheusAuthSection,
                  expanded: _authExpanded,
                  onToggle: () {
                    setState(() => _authExpanded = !_authExpanded);
                    if (_authExpanded) {
                      // Bring the auth fields into view after the expand animation.
                      Future.delayed(const Duration(milliseconds: 250), () {
                        final at = _authKey.currentContext;
                        if (at != null && at.mounted) {
                          Scrollable.ensureVisible(at,
                              alignment: 1, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                        }
                      });
                    }
                  },
                  children: [
                    // Auth type: its name over the app's select (a Material
                    // dropdown with a floating label; a design
                    // audit).
                    const SizedBox(height: 8),
                    ZestFieldLabel(l10n.monitorPrometheusAuthType),
                    const SizedBox(height: 6),
                    ZestSelect<PrometheusAuthType>(
                      value: _authType,
                      items: [
                        for (final t in PrometheusAuthType.values)
                          ZestSelectItem(
                            t,
                            switch (t) {
                              PrometheusAuthType.none => l10n.monitorPrometheusAuthNone,
                              PrometheusAuthType.basicAuth => l10n.monitorPrometheusAuthBasic,
                              PrometheusAuthType.bearerToken => l10n.monitorPrometheusAuthBearer,
                              PrometheusAuthType.customHeader => l10n.monitorPrometheusAuthCustomHeader,
                            },
                          ),
                      ],
                      onChanged: (v) => setState(() => _authType = v),
                    ),
                    const SizedBox(height: 16),

                    // Conditional auth fields
                    if (_authType == PrometheusAuthType.basicAuth) ...[
                      RecordingMaskedFormField(
                        controller: _basicUserCtrl,
                        mask: (v) => Redactable.username(v).display,
                        decoration: InputDecoration(
                          labelText: l10n.monitorPrometheusBasicUser,
                          prefixIcon: const Icon(LucideIcons.user),
                        ),
                        child: TextField(
                          controller: _basicUserCtrl,
                          decoration: InputDecoration(
                            labelText: l10n.monitorPrometheusBasicUser,
                            prefixIcon: const Icon(LucideIcons.user),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _basicPassCtrl,
                        decoration: InputDecoration(
                          labelText: l10n.monitorPrometheusBasicPassword,
                          prefixIcon: const Icon(LucideIcons.asterisk),
                          suffixIcon: IconButton(
                            tooltip: _showBasicPassword ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                            icon: Icon(_showBasicPassword
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye),
                            onPressed: () => setState(
                                () => _showBasicPassword = !_showBasicPassword),
                          ),
                        ),
                        obscureText: !_showBasicPassword,
                      ),
                    ],

                    if (_authType == PrometheusAuthType.bearerToken)
                      TextField(
                        controller: _bearerCtrl,
                        decoration: InputDecoration(
                          labelText: l10n.monitorPrometheusBearerToken,
                          prefixIcon: const Icon(LucideIcons.keyRound),
                          suffixIcon: IconButton(
                            tooltip: _showBearerToken ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                            icon: Icon(_showBearerToken
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye),
                            onPressed: () => setState(
                                () => _showBearerToken = !_showBearerToken),
                          ),
                        ),
                        obscureText: !_showBearerToken,
                      ),

                    if (_authType == PrometheusAuthType.customHeader) ...[
                      TextField(
                        controller: _customKeyCtrl,
                        decoration: InputDecoration(
                          labelText: l10n.monitorPrometheusCustomHeaderKey,
                          hintText:
                              l10n.monitorPrometheusCustomHeaderKeyHint,
                          prefixIcon: const Icon(LucideIcons.code),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _customValueCtrl,
                        decoration: InputDecoration(
                          labelText:
                              l10n.monitorPrometheusCustomHeaderValue,
                          prefixIcon: const Icon(LucideIcons.type),
                          suffixIcon: IconButton(
                            tooltip: _showCustomValue ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                            icon: Icon(_showCustomValue
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye),
                            onPressed: () => setState(
                                () => _showCustomValue = !_showCustomValue),
                          ),
                        ),
                        obscureText: !_showCustomValue,
                      ),
                    ],
                  ],
                ),

              ],
            ),
    );
  }

  Widget _buildExpansionTile({
    Key? key,
    required IconData icon,
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required List<Widget> children,
  }) {
    return Column(
      key: key,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: AppColors.v3TextSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child:
                      Icon(LucideIcons.chevronDown, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildCertRow({
    required String label,
    required String description,
    required bool isLoaded,
    required String loadedText,
    required String importText,
    required VoidCallback onImport,
    required VoidCallback onClear,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(description,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        if (isLoaded)
          Row(
            children: [
              Icon(LucideIcons.checkCircle2, size: 16, color: AppColors.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text(loadedText,
                    style: TextStyle(
                        color: AppColors.success, fontSize: 13)),
              ),
              TextButton(
                onPressed: onClear,
                child: Text(AppLocalizations.of(context)!
                    .monitorPrometheusCaCertClear),
              ),
            ],
          )
        else
          OutlinedButton.icon(
            icon: const Icon(LucideIcons.upload, size: 18),
            label: Text(importText),
            onPressed: onImport,
          ),
      ],
    );
  }
}

