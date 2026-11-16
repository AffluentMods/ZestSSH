import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// Issue a fresh OpenSSH USER certificate entirely in-app: pick a software
/// key to certify (the subject) and a CA key to sign with, set the key id /
/// principals / validity, and we sign via
/// [SshCertService.issueCertificate] and attach the result to the subject -
/// the exact persistence path [CertImportDialog] uses, so a generated cert
/// and an imported one are indistinguishable afterwards.
///
/// User certs only (the common case). The remote server must be configured
/// to trust the CA key's public half (`TrustedUserCAKeys`) for the cert to
/// grant access.
class CertGenerateDialog extends ConsumerStatefulWidget {
  const CertGenerateDialog({super.key});

  static Future<void> show(BuildContext context) => showZestModal<void>(
        context: context,
        size: ZestModalSize.standard,
        child: const CertGenerateDialog(),
      );

  @override
  ConsumerState<CertGenerateDialog> createState() =>
      _CertGenerateDialogState();
}

/// Validity presets. `null` duration = never expires (0xFFFFFFFFFFFFFFFF on
/// the wire).
enum _Validity {
  d30('30 days', Duration(days: 30)),
  d90('90 days', Duration(days: 90)),
  y1('1 year', Duration(days: 365)),
  never('Never expires', null);

  const _Validity(this.label, this.duration);
  final String label;
  final Duration? duration;
}

class _CertGenerateDialogState extends ConsumerState<CertGenerateDialog> {
  String? _subjectId;
  String? _caId;
  final _keyIdCtrl = TextEditingController();
  final _principalsCtrl = TextEditingController();

  /// The CA key's passphrase, asked for where its key file is encrypted and
  /// no passphrase is saved with it ([_caAsksPassphrase]): such a CA could
  /// not sign (no passphrase was ever passed, and the key did not open).
  final _caPassphraseCtrl = TextEditingController();
  bool _caAsksPassphrase = false;
  _Validity _validity = _Validity.d90;
  bool _busy = false;
  String? _error;

  /// The failure behind [_error] where one did, for Copy details.
  ({String said, Object cause})? _failure;

  @override
  void dispose() {
    _keyIdCtrl.dispose();
    _principalsCtrl.dispose();
    _caPassphraseCtrl.dispose();
    super.dispose();
  }

  /// A CA key picked: whether its passphrase must be typed here (its key
  /// file is encrypted, and none is saved with it).
  Future<void> _onCaChanged(String? id) async {
    setState(() {
      _caId = id;
      _error = null;
      _caAsksPassphrase = false;
      _caPassphraseCtrl.clear();
    });
    if (id == null) return;
    final asks = await caAsksPassphrase(ref.read(identityCrudProvider), id);
    if (mounted && _caId == id) setState(() => _caAsksPassphrase = asks);
  }

  /// Software keys only - a subject we must load as an `SSHKeyPair` to encode
  /// its public half, and a CA whose private key we must sign with. Hardware
  /// tokens keep the private key off-device, so they can't be either here.
  bool _isSoftwareKey(Identity id) =>
      (id.authMethod == 'publicKey' || id.authMethod == 'certificate') &&
      (id.publicKeyData?.isNotEmpty ?? false);

  /// Map the subject key's bare algorithm (from its stored `<algo> <b64>`
  /// public key) to the certificate algorithm to issue. An RSA key gets
  /// the name ssh-keygen writes; the login still signs with SHA-2 (see
  /// [SshCertAlgorithm.forSubjectKey]).
  SshCertAlgorithm? _certAlgoFor(String bareAlgo) =>
      SshCertAlgorithm.forSubjectKey(bareAlgo);

  /// When the subject changes, seed a sensible key id + principal from it -
  /// but never clobber something the user already typed.
  void _onSubjectChanged(String? id, List<Identity> all) {
    setState(() {
      _subjectId = id;
      _error = null;
      if (id == null) return;
      final subject = all.firstWhere((i) => i.id == id);
      if (_keyIdCtrl.text.trim().isEmpty) _keyIdCtrl.text = subject.label;
      if (_principalsCtrl.text.trim().isEmpty) {
        _principalsCtrl.text = subject.username;
      }
    });
  }

  /// The principals field in display form: each remote username masked on its
  /// own, so the list keeps its shape without naming anyone.
  static String _maskedPrincipals(String text) => text
      .split(RegExp(r'[,\s]+'))
      .where((p) => p.isNotEmpty)
      .map((p) => Redactable.username(p).display)
      .join(', ');

  Future<void> _generate(List<Identity> all) async {
    final l10n = AppLocalizations.of(context)!;
    final subjectId = _subjectId;
    final caId = _caId;
    if (subjectId == null || caId == null) return;

    final principals = _principalsCtrl.text
        .split(RegExp(r'[,\s]+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (principals.isEmpty) {
      setState(() => _error = l10n.certGenerateErrorNoPrincipal);
      return;
    }
    final keyId = _keyIdCtrl.text.trim();
    if (keyId.isEmpty) {
      setState(() => _error = l10n.certGenerateErrorNoKeyId);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dao = ref.read(identitiesDaoProvider);
      final subject = all.firstWhere((i) => i.id == subjectId);

      final bareAlgo =
          subject.publicKeyData!.trim().split(RegExp(r'\s+')).first;
      final subjectAlgorithm = _certAlgoFor(bareAlgo);
      if (subjectAlgorithm == null) {
        throw StateError(l10n.certGenerateAlgoUnsupported(bareAlgo));
      }

      final pem = await ref.read(identityCrudProvider).getPrivateKey(subjectId);
      if (pem == null || pem.isEmpty) {
        throw StateError(l10n.certGenerateNoPrivateKey);
      }
      // A subject key that is encrypted opens with the passphrase saved with
      // it (only its public half goes into the certificate).
      final crud = ref.read(identityCrudProvider);
      final subjectPassphrase = SSHKeyPair.isEncryptedPem(pem) ? await crud.getKeyPassphrase(subjectId) : null;
      final pairs = SSHKeyPair.fromPem(pem, subjectPassphrase);
      if (pairs.isEmpty) {
        throw StateError(l10n.certGenerateParseFailed);
      }
      final subjectKey = pairs.first;
      final caPassphrase = _caAsksPassphrase ? _caPassphraseCtrl.text : await crud.getKeyPassphrase(caId);

      final now = DateTime.now().toUtc();
      final validBefore = _validity.duration == null
          ? null
          : now.add(_validity.duration!);
      // Random serial for audit uniqueness; the cert's 32-byte nonce is what
      // actually guarantees signature uniqueness, so this only needs to be
      // distinct-ish, not unpredictable.
      final serial = Random.secure().nextInt(0xFFFFFFFF);

      final svc = ref.read(sshCertServiceProvider);
      final result = await svc.issueCertificate(
        subjectKey: subjectKey,
        subjectAlgorithm: subjectAlgorithm,
        caKeyStorageKey: 'identity_key_$caId',
        // An encrypted CA key opens with the passphrase typed here, or the
        // one saved with it; a key that is not encrypted takes none.
        caPassphrase: caPassphrase == null || caPassphrase.isEmpty ? null : caPassphrase,
        serial: serial,
        keyId: keyId,
        principals: principals,
        validAfter: now,
        validBefore: validBefore,
      );

      // Persist + attach exactly like a freshly imported cert.
      await svc.storeCertForIdentity(subjectId, result.cert.fullBlob);
      await dao.updateIdentity(IdentitiesCompanion(
        id: Value(subjectId),
        authMethod: const Value('certificate'),
        certSerial: Value(result.cert.serialHex),
        certKeyId: Value(result.cert.keyId),
        certPrincipals: Value(result.cert.principals.join(',')),
        certCaFingerprint: Value(result.cert.caFingerprint),
        certValidAfter: Value(result.cert.validAfterDateTime),
        certValidBefore: Value(result.cert.validBeforeOrNull),
      ));
      ref.invalidate(certForIdentityProvider(subjectId));

      if (!mounted) return;
      Navigator.of(context).pop();
      // The toast names the key: masked while recording.
      showTopSnackBar(
        context,
        l10n.certGenerateAttachedTo(
            Redactable.keyName(subject.label).display),
        isSuccess: true,
      );
    } on SSHKeyDecryptError catch (e) {
      // The CA key's passphrase was not right: said as that, beside the
      // field it is typed in.
      setState(() {
        _error = _caAsksPassphrase ? l10n.certGenerateCaPassphraseWrong : l10n.certNotGenerated;
        _failure = (said: _error!, cause: e);
      });
    } catch (e) {
      setState(() {
        _error = l10n.certNotGenerated;
        _failure = (said: _error!, cause: e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The localized label for a validity preset (the enum's own [_Validity.label]
  /// stays as an internal fallback; the UI shows this instead).
  String _validityLabel(AppLocalizations l10n, _Validity v) {
    switch (v) {
      case _Validity.d30:
        return l10n.certGenerateValidity30Days;
      case _Validity.d90:
        return l10n.certGenerateValidity90Days;
      case _Validity.y1:
        return l10n.certGenerateValidity1Year;
      case _Validity.never:
        return l10n.certGenerateValidityNever;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final identitiesAsync = ref.watch(identitiesProvider);
    // An Orchard's keys sign only where this account may see them, and a
    // certificate is attached only to a key it may change.
    final rules = ItemRules.of(ref, 'key');
    final canGenerate = _subjectId != null && _caId != null && !_busy;
    // Recording mode: the key id and principals fields hold identifiers (they
    // are seeded from the subject's name and username), so they swap to
    // read-only masked stand-ins while it is on. The level is watched so the
    // masked text follows a live level change.
    final recording = ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);

    return ZestDialogShell(
      tone: ZestDialogTone.info,
      icon: LucideIcons.filePlus,
      title: l10n.certGenerateTitle,
      subtitle: l10n.certGenerateSubtitle,
      maxWidth: 600,
      secondaryAction: (
        label: l10n.cancel,
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
      ),
      primaryAction: (
        label: _busy
            ? l10n.certGenerateGenerating
            : l10n.certGenerateGenerateAndAttach,
        icon: _busy ? null : LucideIcons.check,
        onPressed: canGenerate
            ? () => _generate(identitiesAsync.valueOrNull ?? const [])
            : null,
      ),
      body: identitiesAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: LinearProgressIndicator(minHeight: 2),
        ),
        error: (e, _) => _ErrorBanner('$e'),
        data: (all) {
          final software = all.where(_isSoftwareKey).where((i) => rules.mayReveal(i.id)).toList();
          final subjects = software.where((i) => rules.mayChange(i.id)).toList();
          if (software.isEmpty || subjects.isEmpty) {
            return _ErrorBanner(l10n.certGenerateNoSoftwareKey);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Label(l10n.certGenerateKeyToCertify),
              _IdentityDropdown(
                items: subjects,
                value: _subjectId,
                hint: l10n.certGeneratePickSubjectHint,
                onChanged: (id) => _onSubjectChanged(id, all),
              ),
              const SizedBox(height: 14),
              _Label(l10n.certGenerateSignedByCaKey),
              _IdentityDropdown(
                items: software,
                value: _caId,
                hint: l10n.certGeneratePickCaHint,
                onChanged: _onCaChanged,
              ),
              if (_caAsksPassphrase) ...[
                const SizedBox(height: 14),
                _Label(l10n.certGenerateCaPassphrase),
                _PlainField(
                  key: const ValueKey('cert-generate-ca-passphrase'),
                  controller: _caPassphraseCtrl,
                  hint: l10n.certGenerateCaPassphraseHint,
                  obscure: true,
                  onChanged: (_) => setState(() => _error = null),
                ),
              ],
              const SizedBox(height: 14),
              _Label(l10n.certGenerateKeyId),
              if (recording)
                _MaskedPlainField(
                  text: Redactable.keyName(_keyIdCtrl.text).display,
                  hint: l10n.certGenerateKeyIdHint,
                )
              else
                _PlainField(
                  controller: _keyIdCtrl,
                  hint: l10n.certGenerateKeyIdHint,
                  onChanged: (_) => setState(() => _error = null),
                ),
              const SizedBox(height: 14),
              _Label(l10n.certGeneratePrincipalsLabel),
              if (recording)
                _MaskedPlainField(
                  text: _maskedPrincipals(_principalsCtrl.text),
                  hint: l10n.certGeneratePrincipalsHint,
                )
              else
                _PlainField(
                  controller: _principalsCtrl,
                  hint: l10n.certGeneratePrincipalsHint,
                  onChanged: (_) => setState(() => _error = null),
                ),
              const SizedBox(height: 14),
              _Label(l10n.certGenerateValidFor),
              ZestSelect<_Validity>(
                value: _validity,
                items: [for (final v in _Validity.values) ZestSelectItem(v, _validityLabel(l10n, v))],
                onChanged: (v) => setState(() => _validity = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                _ErrorBanner(_error!, cause: _failure?.said == _error ? _failure?.cause : null),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.v3TextSecondary,
            letterSpacing: 0.6,
          ),
        ),
      );
}

class _IdentityDropdown extends ConsumerWidget {
  const _IdentityDropdown({
    required this.items,
    required this.value,
    required this.hint,
    required this.onChanged,
  });
  final List<Identity> items;
  final String? value;
  final String hint;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The app's select (a Material dropdown with an underline; found in a design
    // audit).
    return ZestSelect<String>(
      value: value,
      hint: hint,
      items: [
        // The key's name and (when it has no type) its username are
        // identifiers; the algorithm is not.
        for (final id in items)
          ZestSelectItem(
            id.id,
            '${Redactable.keyName(id.label).displayIn(ref)}  ·  '
            '${id.keyType ?? Redactable.username(id.username).displayIn(ref)}',
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class _PlainField extends StatelessWidget {
  const _PlainField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.obscure = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  /// A passphrase: not shown as it is typed.
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      obscureText: obscure,
      enableSuggestions: !obscure,
      autocorrect: !obscure,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle:
            TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
      ),
    );
  }
}

/// The recording-mode stand-in for a [_PlainField] that holds an identifier
/// (the key id, the principals). Read-only, its own controller carries the
/// masked text (the real controller is neither painted nor written), and a
/// tap runs the reveal gate: turning the mode off there brings the editable
/// field back on rebuild.
class _MaskedPlainField extends StatefulWidget {
  const _MaskedPlainField({required this.text, required this.hint});

  /// The already-masked display text.
  final String text;
  final String hint;

  @override
  State<_MaskedPlainField> createState() => _MaskedPlainFieldState();
}

class _MaskedPlainFieldState extends State<_MaskedPlainField> {
  late final TextEditingController _masked =
      TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(_MaskedPlainField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != _masked.text) _masked.text = widget.text;
  }

  @override
  void dispose() {
    _masked.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.recModeTooltipOn,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => confirmRevealWhileRecording(context),
          // Purely visual: pointer events go to the gate above, and the field
          // is not a tab stop.
          child: IgnorePointer(
            child: TextField(
              controller: _masked,
              readOnly: true,
              canRequestFocus: false,
              showCursor: false,
              enableInteractiveSelection: false,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
                suffixIcon: const Icon(LucideIcons.video, size: 16),
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 24, minHeight: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message, {this.cause});
  final String message;

  /// What failed, for Copy details.
  final Object? cause;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertCircle, size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: TextStyle(fontSize: 12, color: AppColors.error)),
                if (cause case final why?)
                  CopyDetailsButton(detail: ErrorReport.build(what: message, where: 'Making a certificate', error: why)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the key [identityId] (a CA picked to sign with) asks for its
/// passphrase in the dialog: its key file is encrypted, and no passphrase is
/// saved with it.
Future<bool> caAsksPassphrase(IdentityCrudNotifier crud, String identityId) async {
  final pem = await crud.getPrivateKey(identityId);
  if (pem == null || !SSHKeyPair.isEncryptedPem(pem)) return false;
  final saved = await crud.getKeyPassphrase(identityId);
  return saved == null || saved.isEmpty;
}
