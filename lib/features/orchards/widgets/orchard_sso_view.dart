import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart' show BusinessServicesState;
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart' show OrchardDomain;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sso/oidc_issuer.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_directory_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_domains_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart' show kTeamNarrow;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled, BrowserSignInFailed;
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:zestssh/services/account/sso_gate_refusal.dart';

// An Orchard's company sign-in (3.0), on the Team page's
// Sign-in page (owners). The owner enters the company's identity provider
// (SAML or OIDC); ZestSSH Cloud registers it with Identity Platform, and it
// stays off until a sign-in through it proves it works. It answers only for
// the Orchard's proven domains. Nothing secret comes back from the server:
// a SAML certificate is shown by when it runs out, and an OIDC client secret
// is only ever sent.

/// A certificate this close to running out is worth a word.
const _certificateWarning = Duration(days: 30);

/// What went wrong with company sign-in, in words a person can act on.
String ssoErrorMessage(Object error, AppLocalizations l10n) {
  // The owner's test sign-in, stopped by the sign-in gate (3.0 backend):
  // an address outside the proven domains, or no answer.
  if (error is FirebaseAuthException) {
    switch (ssoGateRefusalOf(error)) {
      case SsoGateRefusal.outsideDomains:
        return l10n.ssoErrorDomainMismatch;
      case SsoGateRefusal.notChecked:
        return l10n.ssoSignInGateUnreachable;
      case null:
        break;
    }
  }
  // The website said the test did not work (3.3.0): what to check, or the
  // provider's code with what it said behind Copy details.
  if (error is BrowserSignInFailed) {
    if (error.detail.contains('sso-gate-refused')) return l10n.ssoErrorDomainMismatch;
    if (error.detail.contains('sso-gate-unreachable')) return l10n.ssoSignInGateUnreachable;
    return switch (error.code) {
      'auth/invalid-credential' || 'auth/internal-error' || 'auth/invalid-idp-response' => l10n.ssoTestNotAccepted,
      _ => l10n.ssoTestFailedCode(error.code),
    };
  }
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'domain-required':
        return l10n.ssoNeedsDomain;
      // ZestSSH Cloud registers no provider before its sign-in gate stands,
      // and counts a test only where the gate saw it.
      case 'sso-gate-off':
        return l10n.ssoErrorGateOff;
      case 'sso-gate-not-seen':
        return l10n.ssoErrorGateNotSeen;
      case 'provider-rejected':
        return l10n.ssoErrorProviderRejected;
      case 'sso-test-failed':
        return l10n.ssoErrorTestFailed;
      case 'sso-domain-mismatch':
        return l10n.ssoErrorDomainMismatch;
      case 'sso-required-by-rules':
        return l10n.ssoErrorRequiredByRules;
      case 'rate-limited':
        return l10n.ssoErrorRateLimited;
      case 'forbidden':
        return l10n.orchardErrorRefused;
    }
  }
  return orchardErrorMessage(error, l10n);
}

class OrchardSsoView extends ConsumerStatefulWidget {
  const OrchardSsoView(
      {super.key, required this.orchardId, this.testSignIn, this.cancelTest, this.intro = true});

  final String orchardId;

  /// Stops a test that waits for the browser (tests put their own; the
  /// browser sign-in's own Cancel otherwise).
  final VoidCallback? cancelTest;

  /// Whether it says first what company sign-in is (the Sign-in page's
  /// step says it above).
  final bool intro;

  /// A sign-in through the provider for the test, or null when the person
  /// closed it. Phones sign in on a Firebase app of their own (its ID
  /// token), desktop through the website (a one-time code for this app's
  /// secret), unless given (tests).
  final Future<SsoTestSignIn?> Function(String providerId)? testSignIn;

  @override
  ConsumerState<OrchardSsoView> createState() => _OrchardSsoViewState();
}

class _OrchardSsoViewState extends ConsumerState<OrchardSsoView> {
  OrchardSso? _sso;
  SsoKind _kind = SsoKind.saml;
  final _name = TextEditingController();
  final _ssoUrl = TextEditingController();
  final _entityId = TextEditingController();
  final _certificate = TextEditingController();
  final _issuer = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();

  /// Typing a new client secret in place of the saved one (Replace).
  bool _replacingSecret = false;

  /// What is running: 'save', 'test', 'on' or 'remove'.
  String? _busy;
  String? _error;

  /// What failed, for Copy details (the page showed the sentence alone;
  /// the error went to the log).
  String? _errorReport;

  void _failed(Object e, StackTrace st, String where) {
    if (!mounted) return;
    final said = ssoErrorMessage(e, AppLocalizations.of(context)!);
    setState(() {
      _error = said;
      _errorReport = ErrorReport.build(what: said, where: 'Company sign-in: $where', error: e, stack: st);
    });
  }

  /// The field the server refused, and why.
  ({String field, String code})? _fieldError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _ssoUrl, _entityId, _certificate, _issuer, _clientId, _clientSecret]) {
      c.dispose();
    }
    super.dispose();
  }

  OrchardSsoApi get _api => ref.read(orchardSsoApiProvider);

  Future<void> _load() async {
    try {
      _show(await _api.get(widget.orchardId));
    } catch (e, st) {
      AppLogger.warning('Company sign-in: could not be read ($e)');
      _failed(e, st, 'reading it');
    }
  }

  /// Shows [sso] and fills the form from it; secrets stay empty.
  void _show(OrchardSso sso) {
    if (!mounted) return;
    setState(() {
      _sso = sso;
      _kind = sso.kind ?? _kind;
      _name.text = sso.displayName ?? _name.text;
      if (sso.kind == SsoKind.saml) {
        _ssoUrl.text = sso.config['sso_url'] ?? '';
        _entityId.text = sso.config['idp_entity_id'] ?? '';
        _certificate.clear();
      } else if (sso.kind == SsoKind.oidc) {
        _issuer.text = sso.config['issuer'] ?? '';
        _clientId.text = sso.config['client_id'] ?? '';
        _clientSecret.clear();
        _replacingSecret = false;
      }
    });
    ref.invalidate(orchardSsoProvider(widget.orchardId));
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() {
      _busy = key;
      _error = null;
      _errorReport = null;
      _fieldError = null;
    });
    try {
      await action();
    } on SsoFieldInvalid catch (e) {
      if (mounted) setState(() => _fieldError = (field: e.field, code: e.code ?? 'invalid-sso'));
    } catch (e, st) {
      AppLogger.warning('Company sign-in: $key did not happen ($e)');
      _failed(e, st, key);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Whether the provider kept is of the kind shown, so a certificate or a
  /// secret left empty stays as it is.
  bool get _keeps => _sso?.kind == _kind;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    await _run('save', () async {
      String? filled(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      // The issuer exactly as the provider gives it in its tokens: a slash
      // at the end is put right; another address is filled in to check.
      if (_kind == SsoKind.oidc) {
        final typed = _issuer.text.trim();
        final said = await ref.read(oidcIssuerReaderProvider)(typed);
        if (!mounted) return;
        if (said == null) throw const SsoFieldInvalid('issuer', 'issuer-unreadable');
        if (said != typed) {
          setState(() => _issuer.text = said);
          if (!sameIssuerButSlash(said, typed)) throw const SsoFieldInvalid('issuer', 'issuer-filled-in');
        }
      }
      Future<void> put() async {
        final saved = _kind == SsoKind.saml
            ? await _api.setSaml(
                widget.orchardId,
                displayName: _name.text.trim(),
                ssoUrl: _ssoUrl.text.trim(),
                idpEntityId: _entityId.text.trim(),
                certificate: filled(_certificate) ?? (_keeps ? null : ''),
              )
            : await _api.setOidc(
                widget.orchardId,
                displayName: _name.text.trim(),
                issuer: _issuer.text.trim(),
                clientId: _clientId.text.trim(),
                clientSecret: filled(_clientSecret) ?? (_keeps ? null : ''),
              );
        _show(saved);
      }

      // Who can sign in to the Orchard, and how: a recent sign-in first.
      if (await withRecentSignIn(context, ref, put, summary: (what: l10n.stepUpSsoChange, effects: const [])) &&
          mounted) {
        showTopSnackBar(context, l10n.ssoSaved, isSuccess: true);
      }
    });
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _sso?.providerId;
    if (provider == null) return;
    await _run('test', () async {
      // Phones sign in through it on a Firebase app of their own; desktop
      // through the website, which hands the sign-in back.
      Future<SsoTestSignIn?> onThisDevice() async {
        final token = await AuthService.ssoTestToken(provider);
        return token == null ? null : SsoTestSignIn.idToken(token);
      }

      final signIn = widget.testSignIn;
      final SsoTestSignIn? proof;
      try {
        proof = signIn != null
            ? await signIn(provider)
            : AuthService.isFirebaseAvailable
                ? await onThisDevice()
                : await DesktopBrowserSignIn.ssoTest(provider);
      } on BrowserSignInCancelled {
        // Cancel while it waited: nothing to say.
        return;
      }
      if (proof == null || !mounted) return;
      final tested = await _api.test(widget.orchardId, proof);
      _show(tested);
      if (mounted) showTopSnackBar(context, l10n.ssoTestedToast(tested.testedEmail ?? ''), isSuccess: true);
    });
  }

  Future<void> _turnOn() async {
    final l10n = AppLocalizations.of(context)!;
    await _run('on', () async {
      if (await withRecentSignIn(context, ref, () async => _show(await _api.activate(widget.orchardId)),
              summary: (what: l10n.stepUpSsoTurnOn, effects: const [])) &&
          mounted) {
        showTopSnackBar(context, l10n.ssoTurnedOn, isSuccess: true);
      }
    });
  }

  Future<void> _remove() async {
    final l10n = AppLocalizations.of(context)!;
    final sso = _sso;
    if (sso == null) return;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.ssoRemoveTitle,
      body: l10n.ssoRemoveBody(sso.displayName ?? ''),
      confirmLabel: l10n.ssoRemove,
    );
    if (ok != true || !mounted) return;
    await _run('remove', () async {
      if (await withRecentSignIn(context, ref, () => _api.remove(widget.orchardId),
              summary: (what: l10n.stepUpSsoRemove, effects: const [])) &&
          mounted) {
        showTopSnackBar(context, l10n.ssoRemoved, isSuccess: true);
        _clearForm();
        await _load();
      }
    });
  }

  void _clearForm() {
    for (final c in [_name, _ssoUrl, _entityId, _certificate, _issuer, _clientId, _clientSecret]) {
      c.clear();
    }
  }

  String? _errorFor(String field, AppLocalizations l10n) {
    final e = _fieldError;
    if (e == null || e.field != field) return null;
    return switch (e.code) {
      'certificate-expired' => l10n.ssoCertificateExpired,
      'issuer-unreadable' => l10n.ssoIssuerUnreadable,
      'issuer-filled-in' => l10n.ssoIssuerFilledIn,
      _ => l10n.ssoCheckField,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sso = _sso;
    if (sso == null) {
      return _error == null
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
            )
          : _ErrorLine(_error!, report: _errorReport);
    }
    final noDomain = sso.domains.isEmpty;
    final idle = _busy == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.intro) ...[
          Text(l10n.ssoSectionIntro, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 10),
        ],
        if (noDomain)
          _Notice(key: const ValueKey('sso-needs-domain'), icon: LucideIcons.globe, text: l10n.ssoNeedsDomain)
        else ...[
          _Status(sso: sso),
          const SizedBox(height: 12),
          _KindChoice(
            kind: _kind,
            onChanged: idle
                ? (k) => setState(() {
                      _kind = k;
                      _fieldError = null;
                    })
                : null,
          ),
          const SizedBox(height: 12),
          _TellProvider(kind: _kind, service: sso.service),
          const SizedBox(height: 12),
          _Field(
            key: const ValueKey('sso-name'),
            controller: _name,
            label: l10n.ssoFieldName,
            hint: l10n.ssoFieldNameHint,
            error: _errorFor('display_name', l10n),
          ),
          if (_kind == SsoKind.saml) ...[
            _Field(
              key: const ValueKey('sso-url'),
              controller: _ssoUrl,
              label: l10n.ssoFieldSsoUrl,
              hint: 'https://',
              error: _errorFor('sso_url', l10n),
              mono: true,
            ),
            _Field(
              key: const ValueKey('sso-entity'),
              controller: _entityId,
              label: l10n.ssoFieldEntityId,
              error: _errorFor('idp_entity_id', l10n),
              mono: true,
            ),
            _Field(
              key: const ValueKey('sso-certificate'),
              controller: _certificate,
              label: l10n.ssoFieldCertificate,
              hint: _keeps ? l10n.ssoFieldCertificateKeep : '-----BEGIN CERTIFICATE-----',
              error: _errorFor('certificate', l10n),
              mono: true,
              lines: 4,
            ),
            if (_keeps && sso.certificateValidTo != null) _CertificateLine(validTo: sso.certificateValidTo!),
          ] else ...[
            _Field(
              key: const ValueKey('sso-issuer'),
              controller: _issuer,
              label: l10n.ssoFieldIssuer,
              hint: 'https://',
              error: _errorFor('issuer', l10n),
              mono: true,
            ),
            _Field(
              key: const ValueKey('sso-client-id'),
              controller: _clientId,
              label: l10n.ssoFieldClientId,
              error: _errorFor('client_id', l10n),
              mono: true,
            ),
            // A saved secret is never sent back: shown as there and hidden,
            // with Replace (it looked gone before).
            if (_keeps && !_replacingSecret && _fieldError?.field != 'client_secret')
              _SavedSecret(
                key: const ValueKey('sso-client-secret-saved'),
                label: l10n.ssoFieldClientSecret,
                saved: l10n.ssoSecretSaved,
                replace: l10n.ssoSecretReplace,
                info: l10n.ssoSecretInfo,
                onReplace: idle ? () => setState(() => _replacingSecret = true) : null,
              )
            else
              _Field(
                key: const ValueKey('sso-client-secret'),
                controller: _clientSecret,
                label: l10n.ssoFieldClientSecret,
                hint: _keeps ? l10n.ssoFieldClientSecretKeep : null,
                error: _errorFor('client_secret', l10n),
                mono: true,
                obscure: true,
                autofocus: _replacingSecret,
                info: l10n.ssoSecretInfo,
              ),
          ],
          if (sso.active) ...[
            const SizedBox(height: 2),
            Text(l10n.ssoSaveTurnsOff, style: TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.v3Warning)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ZestButton(
                key: const ValueKey('sso-save'),
                label: l10n.save,
                icon: LucideIcons.save,
                variant: sso.isSetUp ? ZestButtonVariant.secondary : ZestButtonVariant.primary,
                isLoading: _busy == 'save',
                onPressed: idle ? _save : null,
              ),
              // While the test waits for the browser, a red Cancel in its
              // place (there was no way to stop
              // it before). A phone's own sign-in sheet has its own close.
              if (sso.isSetUp && _busy == 'test' && (widget.cancelTest != null || !AuthService.isFirebaseAvailable))
                ZestButton(
                  key: const ValueKey('sso-test-cancel'),
                  label: l10n.cancel,
                  icon: LucideIcons.x,
                  variant: ZestButtonVariant.danger,
                  onPressed: widget.cancelTest ?? DesktopBrowserSignIn.cancel,
                )
              else if (sso.isSetUp)
                ZestButton(
                  key: const ValueKey('sso-test'),
                  label: l10n.ssoTest,
                  icon: LucideIcons.logIn,
                  isLoading: _busy == 'test',
                  onPressed: idle ? _test : null,
                ),
              if (sso.isSetUp && !sso.active)
                ZestButton(
                  key: const ValueKey('sso-turn-on'),
                  label: l10n.ssoTurnOn,
                  icon: LucideIcons.power,
                  variant: ZestButtonVariant.primary,
                  isLoading: _busy == 'on',
                  onPressed: idle && sso.isTested ? _turnOn : null,
                ),
              if (sso.isSetUp)
                ZestButton(
                  key: const ValueKey('sso-remove'),
                  label: l10n.ssoRemove,
                  icon: LucideIcons.trash2,
                  variant: ZestButtonVariant.ghost,
                  isLoading: _busy == 'remove',
                  onPressed: idle ? _remove : null,
                ),
            ],
          ),
          if (sso.isSetUp && !sso.isTested) ...[
            const SizedBox(height: 8),
            Text(l10n.ssoTestHint, style: TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.v3TextTertiary)),
          ],
        ],
        if (_error != null) ...[const SizedBox(height: 8), _ErrorLine(_error!, report: _errorReport)],
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.sso});

  final OrchardSso sso;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (icon, color, text) = !sso.isSetUp
        ? (LucideIcons.circleDashed, AppColors.v3TextSecondary, l10n.ssoStatusNotSetUp)
        : sso.active
            ? (LucideIcons.badgeCheck, AppColors.v3Success, l10n.ssoStatusOn(sso.domains.join(', ')))
            : sso.isTested
                ? (LucideIcons.checkCircle, AppColors.v3TextSecondary, l10n.ssoStatusTested)
                : (LucideIcons.hourglass, AppColors.v3Warning, l10n.ssoStatusUntested);
    return Row(
      key: const ValueKey('sso-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary)),
        ),
      ],
    );
  }
}

class _KindChoice extends StatelessWidget {
  const _KindChoice({required this.kind, required this.onChanged});

  final SsoKind kind;
  final ValueChanged<SsoKind>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<SsoKind>(
        key: const ValueKey('sso-kind'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: SsoKind.saml, label: Text(l10n.ssoKindSaml)),
          ButtonSegment(value: SsoKind.oidc, label: Text(l10n.ssoKindOidc)),
        ],
        selected: {kind},
        onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.single),
      ),
    );
  }
}

/// What the company's identity provider needs from ZestSSH, each copyable.
class _TellProvider extends StatelessWidget {
  const _TellProvider({required this.kind, required this.service});

  final SsoKind kind;
  final SsoServiceSide service;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rows = kind == SsoKind.saml
        ? [(l10n.ssoAcsUrl, service.samlAcsUrl), (l10n.ssoSpEntityId, service.samlEntityId)]
        : [(l10n.ssoRedirectUri, service.oidcRedirectUri)];
    return Container(
      key: const ValueKey('sso-tell-provider'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.v3BorderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.ssoTellProvider,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
          for (final (label, value) in rows)
            if (value != null) ...[
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(value, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.copy, size: 14),
                    tooltip: l10n.copy,
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: value));
                      if (context.mounted) showTopSnackBar(context, l10n.ssoCopied, isSuccess: true);
                    },
                  ),
                ],
              ),
            ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.error,
    this.mono = false,
    this.obscure = false,
    this.lines = 1,
    this.autofocus = false,
    this.info,
  });

  final TextEditingController controller;
  final bool autofocus;

  /// What happens to what is typed here, behind the info mark at the end
  /// of the field (the client secret's).
  final String? info;
  final String label;
  final String? hint;
  final String? error;
  final bool mono;
  final bool obscure;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: obscure,
        minLines: lines,
        maxLines: obscure ? 1 : lines,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(fontSize: 13, fontFamily: mono ? 'JetBrainsMono' : null),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          errorText: error,
          suffixIcon: info == null ? null : _InfoMark(info!),
        ),
      ),
    );
  }
}

/// The info mark at the end of a field: what it says shows on hover, and
/// on a tap (phones).
class _InfoMark extends StatelessWidget {
  const _InfoMark(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Tooltip(
        key: const ValueKey('sso-secret-info'),
        message: text,
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(LucideIcons.info, size: 15, color: AppColors.v3TextTertiary),
        ),
      );
}

/// A secret that is saved and never shown: its field, filled with dots and
/// marked as saved, and Replace.
class _SavedSecret extends StatelessWidget {
  const _SavedSecret(
      {super.key,
      required this.label,
      required this.saved,
      required this.replace,
      required this.info,
      required this.onReplace});

  final String label;
  final String saved;
  final String replace;
  final String info;
  final VoidCallback? onReplace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InputDecorator(
        decoration: InputDecoration(isDense: true, labelText: label),
        child: Row(
          children: [
            Expanded(
              child: Text('\u2022' * 16,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono', color: AppColors.v3TextSecondary)),
            ),
            const SizedBox(width: 8),
            Icon(LucideIcons.lock, size: 12, color: AppColors.v3TextTertiary),
            const SizedBox(width: 4),
            Text(saved, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
            const SizedBox(width: 6),
            TextButton(
              key: const ValueKey('sso-client-secret-replace'),
              onPressed: onReplace,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(replace),
            ),
            _InfoMark(info),
          ],
        ),
      ),
    );
  }
}

class _CertificateLine extends StatelessWidget {
  const _CertificateLine({required this.validTo});

  final DateTime validTo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final date = DateFormat.yMMMd(l10n.localeName).format(validTo.toLocal());
    final soon = validTo.difference(DateTime.now()) < _certificateWarning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        soon ? l10n.ssoCertificateSoon(date) : l10n.ssoCertificateValidUntil(date),
        key: const ValueKey('sso-certificate-line'),
        style: TextStyle(fontSize: 11.5, height: 1.4, color: soon ? AppColors.v3Warning : AppColors.v3TextSecondary),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3TextSecondary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppColors.v3TextSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary))),
        ],
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text, {this.report});

  final String text;

  /// What failed, for Copy details.
  final String? report;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              key: const ValueKey('sso-error'), style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3Error)),
          if (report != null) CopyDetailsButton(detail: report!),
        ],
      );
}

/// The Sign-in page as a screen of its own, from the Orchard's menu where
/// the Team page is not at hand.
Future<void> showOrchardSignIn(BuildContext context, OrchardSummary orchard) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.globe,
    title: l10n.teamPageSignIn,
    subtitle: l10n.teamSignInSubtitle,
    body: OrchardSignInView(orchard: orchard),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

/// The Team page's Sign-in page (owners), as three steps:
/// prove the domains, then company sign-in
/// (SSO) and directory sync (SCIM), which answer only for proven domains
/// and are set up only while the team has Business (the server refuses
/// them otherwise). A step that waits for something says what, with a
/// lock; one that is done says so, and still shows what it set up.
class OrchardSignInView extends ConsumerStatefulWidget {
  const OrchardSignInView({super.key, required this.orchard, this.onOpenBusiness});

  final OrchardSummary orchard;

  /// Opens where the team's Business is seen (the Seats page); null where
  /// there is none to open.
  final VoidCallback? onOpenBusiness;

  String get orchardId => orchard.id;

  @override
  ConsumerState<OrchardSignInView> createState() => _OrchardSignInViewState();
}

/// Where a step stands.
enum SignInStepState { current, done, locked }

class _OrchardSignInViewState extends ConsumerState<OrchardSignInView> {
  /// The domains as the first step last read them; null before.
  List<OrchardDomain>? _domains;

  void _domainsRead(List<OrchardDomain> list) {
    final before = _domains?.where((d) => d.verified).length;
    setState(() => _domains = list);
    // A domain proven or dropped: company sign-in's own list changes too.
    final after = list.where((d) => d.verified).length;
    if (before != null && before != after) ref.invalidate(orchardSsoProvider(widget.orchardId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = widget.orchard;
    final sso = ref.watch(orchardSsoProvider(orchard.id)).valueOrNull;
    final billing = ref.watch(orchardBillingProvider(orchard.id)).valueOrNull;
    final directoryOn = ref.watch(orchardDirectoryProvider(directoryReaderOf(orchard))).valueOrNull != null;
    final domains = _domains;
    final anyProven = (domains?.any((d) => d.verified) ?? false) || (sso?.domains.isNotEmpty ?? false);
    final waiting = domains?.where((d) => !d.verified).firstOrNull?.domain;
    // Business as ZestSSH Cloud last said; while it is not known, nothing
    // is locked for it (the server says so if it is needed).
    final businessOff = billing != null && billing.services.state != BusinessServicesState.active;
    final known = domains != null || sso != null;
    final ssoSetUp = sso?.isSetUp ?? false;

    /// What a later step waits for: a proven domain, Business, or both.
    Widget? lockFor({required bool needsDomain, required bool needsBusiness, required String key}) {
      if (!needsDomain && !needsBusiness) return null;
      return _StepLock(
        key: ValueKey(key),
        text: [
          if (needsDomain) waiting != null ? l10n.teamSignInUnlocksWhenProven(waiting) : l10n.teamSignInUnlocksWhenAnyProven,
          if (needsBusiness) l10n.teamSignInBusinessOff,
        ].join(' '),
        linkLabel: needsBusiness && widget.onOpenBusiness != null ? l10n.teamSeeBusiness : null,
        onLink: widget.onOpenBusiness,
      );
    }

    final ssoLock = !known
        ? null
        : lockFor(needsDomain: !anyProven && !ssoSetUp, needsBusiness: businessOff && !ssoSetUp, key: 'signin-sso-locked');
    final directoryLock = !known
        ? null
        : lockFor(needsDomain: !anyProven && !directoryOn, needsBusiness: businessOff && !directoryOn, key: 'signin-directory-locked');
    final businessPill = businessOff ? _BusinessPill(text: l10n.teamSignInNeedsBusiness) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SignInStep(
          key: const ValueKey('signin-step-domains'),
          number: 1,
          state: anyProven ? SignInStepState.done : SignInStepState.current,
          title: l10n.teamSignInProveDomains,
          intro: l10n.orchardDomainsSubtitle,
          last: false,
          child: OrchardDomainsView(orchardId: orchard.id, onRead: _domainsRead),
        ),
        _SignInStep(
          key: const ValueKey('signin-step-sso'),
          number: 2,
          state: sso?.active == true
              ? SignInStepState.done
              : (!known || ssoLock != null)
                  ? SignInStepState.locked
                  : SignInStepState.current,
          title: l10n.ssoSectionTitle,
          badge: businessPill,
          intro: l10n.ssoSectionIntro,
          last: false,
          child: !known ? null : ssoLock ?? OrchardSsoView(orchardId: orchard.id, intro: false),
        ),
        _SignInStep(
          key: const ValueKey('signin-step-directory'),
          number: 3,
          state: directoryOn
              ? SignInStepState.done
              : (!known || directoryLock != null)
                  ? SignInStepState.locked
                  : SignInStepState.current,
          title: l10n.directorySectionTitle,
          badge: businessPill,
          intro: l10n.directoryIntro,
          last: true,
          child: !known ? null : directoryLock ?? OrchardDirectoryView(orchard: orchard, intro: false),
        ),
      ],
    );
  }
}

/// One step: its number on the rail at the start (a check once done, a
/// lock while it waits), joined to the next by a line, and its card.
class _SignInStep extends StatelessWidget {
  const _SignInStep({
    super.key,
    required this.number,
    required this.state,
    required this.title,
    required this.intro,
    required this.last,
    this.badge,
    this.child,
  });

  final int number;
  final SignInStepState state;
  final String title;
  final String intro;
  final bool last;
  final Widget? badge;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < kTeamNarrow;
      final card = Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 20, narrow ? 14 : 18, narrow ? 16 : 20, narrow ? 16 : 20),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.teamSignInStep(number).toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: ZestTokens.textTertiary,
                  ),
                ),
                Text(title,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary)),
                if (state == SignInStepState.done)
                  Icon(LucideIcons.checkCircle2, key: ValueKey('signin-step-$number-done'), size: 15, color: ZestTokens.statusHealthy),
                ?badge,
              ],
            ),
            const SizedBox(height: 6),
            Text(intro, style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
            if (child != null) ...[const SizedBox(height: 14), child!],
          ],
        ),
      );
      if (narrow) return Padding(padding: const EdgeInsets.only(bottom: 14), child: card);
      return Stack(
        children: [
          // The line down to the next step, under the marks.
          if (!last)
            PositionedDirectional(
              start: 15,
              top: 34,
              bottom: 0,
              child: Container(width: 1.5, color: ZestTokens.border),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StepMark(number: number, state: state),
                const SizedBox(width: 18),
                Expanded(child: card),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark({required this.number, required this.state});

  final int number;
  final SignInStepState state;

  @override
  Widget build(BuildContext context) {
    final (Color ring, Color fill, Widget inner) = switch (state) {
      SignInStepState.current => (
          ZestTokens.brand,
          ZestTokens.brand.withValues(alpha: 0.12),
          Text('$number', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZestTokens.brandInk)),
        ),
      SignInStepState.done => (
          ZestTokens.statusHealthy.withValues(alpha: 0.6),
          ZestTokens.statusHealthy.withValues(alpha: 0.14),
          Icon(LucideIcons.check, size: 15, color: ZestTokens.statusHealthy),
        ),
      SignInStepState.locked => (
          ZestTokens.border,
          ZestTokens.surfaceRaised,
          Icon(LucideIcons.lock, size: 13, color: ZestTokens.textTertiary),
        ),
    };
    return Container(
      width: 32,
      height: 32,
      margin: const EdgeInsets.only(top: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 1.5),
      ),
      child: inner,
    );
  }
}

/// What a step waits for, with a lock, and a link where there is one.
class _StepLock extends StatelessWidget {
  const _StepLock({super.key, required this.text, this.linkLabel, this.onLink});

  final String text;
  final String? linkLabel;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.lock, size: 13, color: ZestTokens.textTertiary),
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary))),
          ],
        ),
        if (linkLabel != null && onLink != null)
          TextButton(
            key: const ValueKey('signin-see-business'),
            onPressed: onLink,
            style: TextButton.styleFrom(
              foregroundColor: ZestTokens.brandInk,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            child: Text(linkLabel!),
          ),
      ],
    );
  }
}

/// "Needs Business", in the accent's tint.
class _BusinessPill extends StatelessWidget {
  const _BusinessPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.brand.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.brand.withValues(alpha: 0.30)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
    );
  }
}
