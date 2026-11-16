import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Modal dialog for importing an OpenSSH user certificate and attaching
/// it to one of the user's existing software keys.
///
/// Flow:
///   1. Paste an `id_*-cert.pub` line (or pick a file).
///   2. Parse + validate; show the cert details (key id, principals,
///      validity, CA fingerprint, key match status).
///   3. User picks the matching identity from a dropdown filtered to
///      keys with the right algorithm + matching public key.
///   4. On confirm, persist the cert blob + mirror metadata into
///      Drift, flip the identity's authMethod to "certificate".
class CertImportDialog extends ConsumerStatefulWidget {
  const CertImportDialog({super.key, this.forIdentityId});

  /// The key a certificate is added to from its own editor (a phone's key
  /// editor, 4.0): picked at once where the certificate is for it. The list
  /// still shows every key, and Attach still checks the certificate against
  /// the key it is attached to.
  final String? forIdentityId;

  static Future<void> show(BuildContext context, {String? forIdentityId}) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: CertImportDialog(forIdentityId: forIdentityId),
    );
  }

  @override
  ConsumerState<CertImportDialog> createState() => _CertImportDialogState();
}

class _CertImportDialogState extends ConsumerState<CertImportDialog> {
  final _pasteController = TextEditingController();
  SshCertificate? _parsed;
  String? _parseError;
  // Why the reader refused what was pasted, in its own (English) words: for
  // Copy details, never the sentence shown.
  Object? _parseCause;
  String? _selectedIdentityId;
  bool _busy = false;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  void _tryParse() {
    setState(() {
      _parseError = null;
      _parseCause = null;
      _parsed = null;
    });
    final text = _pasteController.text;
    if (text.trim().isEmpty) return;
    try {
      final cert = ref.read(sshCertServiceProvider).parseImported(text);
      // A host's certificate names a server to the people who connect to
      // it: it signs no one in. Refused here, with what it is (it could be
      // attached, and the sign-in then failed for another reason).
      if (cert.type == SshCertType.host) {
        setState(() => _parseError = AppLocalizations.of(context)!.certImportHostCertRefused);
        return;
      }
      setState(() {
        _parsed = cert;
        // The key whose editor asked, picked where the certificate is for it.
        final mine = widget.forIdentityId;
        if (mine != null && _selectedIdentityId == null) {
          final key = ref.read(identitiesProvider).valueOrNull?.where((i) => i.id == mine).firstOrNull;
          final rules = ItemRules.of(ref, 'key', watch: false);
          if (key != null && rules.mayChange(mine) && rules.mayReveal(mine) && _isCompatible(key, cert)) {
            _selectedIdentityId = mine;
          }
        }
      });
    } catch (e) {
      // The reader's reasons are English ("SSH cert: invalid base64 ..."):
      // the person is told what to do in their language, and the reason is
      // kept for Copy details.
      setState(() {
        _parseError = AppLocalizations.of(context)!.certImportNotReadable;
        _parseCause = e;
      });
    }
  }

  Future<void> _pickFile() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: l10n.certImportPickFileDialogTitle,
      type: FileType.any,
      withData: true,
      allowMultiple: false,
      // Open straight to ~/.ssh (desktop) - certs sit beside their keys.
      initialDirectory: defaultSshPickerDirectory(),
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _toast(l10n.certImportCouldNotReadBytes, error: true);
      return;
    }
    final text = String.fromCharCodes(bytes);
    _pasteController.text = text;
    _tryParse();
  }

  /// Filter the identity list to only those whose key algorithm
  /// matches the imported cert AND whose public key bytes match the
  /// cert's embedded subject key. The dropdown shows everyone but
  /// disables non-matches with a clear reason - gives the user
  /// transparency about why their key isn't selectable.
  List<_CandidateIdentity> _candidates(
      List<Identity> all, SshCertificate cert) {
    return [
      for (final id in all)
        _CandidateIdentity(
          identity: id,
          isCompatible: _isCompatible(id, cert),
        ),
    ];
  }

  bool _isCompatible(Identity id, SshCertificate cert) {
    if (id.authMethod != 'publicKey' && id.authMethod != 'certificate') {
      return false;
    }
    final pub = id.publicKeyData;
    if (pub == null || pub.isEmpty) return false;
    // The on-disk publicKeyData is already in OpenSSH `<algo> <b64>` form:
    // the certificate's own key must be it, not only of its kind (a key of
    // the same algorithm could be picked, and only Attach said no).
    return ref.read(sshCertServiceProvider).certMatchesPublicKey(cert, pub);
  }

  Future<void> _confirm() async {
    final cert = _parsed;
    final identityId = _selectedIdentityId;
    if (cert == null || identityId == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      // Cross-check key match. We already filtered by algorithm; here
      // we verify the actual public-key bytes line up. This is the
      // single most-important security check in this flow - without
      // it a malicious cert containing a third party's key would be
      // attached to *this user's* private key, leaking auth attempts
      // intended for the wrong key.
      final dao = ref.read(identitiesDaoProvider);
      final identity = await dao.getById(identityId);
      if (identity == null) {
        throw StateError(l10n.certImportIdentityDisappeared);
      }
      final svc = ref.read(sshCertServiceProvider);
      if (!svc.certMatchesPublicKey(cert, identity.publicKeyData ?? '')) {
        throw StateError(l10n.certImportCertKeyMismatch);
      }
      final crud = ref.read(identityCrudProvider);
      final pem = await crud.getPrivateKey(identityId);
      if (pem == null) {
        throw StateError(l10n.certImportPrivateKeyMissing);
      }
      // The private key is checked too where it can be read: unencrypted,
      // or with the passphrase saved with it (an encrypted one was read
      // without it, and could not be attached to at all). One that asks for
      // its passphrase at sign-in is held to its public key, above.
      final encrypted = SSHKeyPair.isEncryptedPem(pem);
      final passphrase = encrypted ? await crud.getKeyPassphrase(identityId) : null;
      if (!encrypted || (passphrase != null && passphrase.isNotEmpty)) {
        final pairs = SSHKeyPair.fromPem(pem, passphrase);
        if (pairs.isEmpty) {
          throw StateError(l10n.certImportPemNoKeyPairs);
        }
        if (!svc.certMatchesKey(cert, pairs.first)) {
          throw StateError(l10n.certImportCertKeyMismatch);
        }
      }

      // Persist the cert + mirror metadata.
      await svc.storeCertForIdentity(identityId, cert.fullBlob);
      await dao.updateIdentity(IdentitiesCompanion(
        id: Value(identityId),
        authMethod: const Value('certificate'),
        certSerial: Value(cert.serialHex),
        certKeyId: Value(cert.keyId),
        certPrincipals: Value(cert.principals.join(',')),
        certCaFingerprint: Value(cert.caFingerprint),
        certValidAfter: Value(cert.validAfterDateTime),
        certValidBefore: Value(cert.validBeforeOrNull),
      ));

      ref.invalidate(certForIdentityProvider(identityId));

      if (!mounted) return;
      Navigator.of(context).pop();
      // The toast names the key: masked while recording.
      _toast(l10n.certImportCertAttachedTo(
          Redactable.keyName(identity.label).display));
    } catch (e) {
      _toast(l10n.certNotImported, error: true, cause: e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg, {bool error = false, Object? cause}) {
    showTopSnackBar(context, msg, isError: error, details: cause == null ? null : '$cause');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final identitiesAsync = ref.watch(identitiesProvider);
    // A certificate goes only on an Orchard key this account may change and
    // see (it reads the key to check the certificate).
    final rules = ItemRules.of(ref, 'key');
    final canConfirm =
        _parsed != null && _selectedIdentityId != null && !_busy;

    return ZestDialogShell(
      tone: ZestDialogTone.info,
      icon: LucideIcons.fileBadge2,
      title: l10n.certImportTitle,
      subtitle: l10n.certImportSubtitle,
      maxWidth: 600,
      tertiaryAction: (
        label: l10n.certImportPickFile,
        onPressed: _busy ? null : _pickFile,
      ),
      secondaryAction: (
        label: l10n.cancel,
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
      ),
      primaryAction: (
        label: _busy ? l10n.certImportImporting : l10n.certImportAttachCertificate,
        icon: _busy ? null : LucideIcons.check,
        onPressed: canConfirm ? _confirm : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mono-styled paste field with subtle accent on focus.
          Container(
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.v3BorderSubtle,
              ),
            ),
            child: TextField(
              controller: _pasteController,
              maxLines: 5,
              minLines: 4,
              onChanged: (_) => _tryParse(),
              style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: AppColors.v3TextPrimary,
                  height: 1.4),
              decoration: InputDecoration(
                hintText:
                    'ssh-ed25519-cert-v01@openssh.com AAAA…  user@host',
                hintStyle: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: AppColors.v3TextTertiary,
                ),
                isDense: true,
                filled: false,
                contentPadding: const EdgeInsets.all(12),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
              ),
              inputFormatters: [
                // Don't allow the user to paste 1 MB of garbage.
                LengthLimitingTextInputFormatter(64 * 1024),
              ],
            ),
          ),
          if (_parseError != null) ...[
            const SizedBox(height: 10),
            _ErrorBanner(_parseError!, cause: _parseCause),
          ],
          if (_parsed != null) ...[
            const SizedBox(height: 16),
            _CertSummary(cert: _parsed!),
            const SizedBox(height: 18),
            Text(
              l10n.certImportAttachToIdentity,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.v3TextSecondary,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 8),
            identitiesAsync.when(
              data: (list) => _IdentityPicker(
                candidates: _candidates(
                    [
                      for (final i in list)
                        if (rules.mayChange(i.id) && rules.mayReveal(i.id)) i,
                    ],
                    _parsed!),
                selectedId: _selectedIdentityId,
                onSelect: (id) =>
                    setState(() => _selectedIdentityId = id),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              error: (e, _) => _ErrorBanner('$e'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CandidateIdentity {
  _CandidateIdentity({required this.identity, required this.isCompatible});
  final Identity identity;
  final bool isCompatible;
}

class _IdentityPicker extends ConsumerWidget {
  const _IdentityPicker({
    required this.candidates,
    required this.selectedId,
    required this.onSelect,
  });
  final List<_CandidateIdentity> candidates;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Watched so the rows re-mask live when recording mode (or its level)
    // toggles; the row builder runs outside this build and uses `.display`.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    if (candidates.where((c) => c.isCompatible).isEmpty) {
      return _ErrorBanner(l10n.certImportNoCompatibleIdentity);
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      constraints: const BoxConstraints(maxHeight: 200),
      // The rows' own Material: under the box's colour their pressed and
      // picked looks did not show (and Flutter's checks stopped on it once a
      // certificate could be read and the keys were listed).
      child: Material(
        type: MaterialType.transparency,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: candidates.length,
          itemBuilder: (_, i) {
            final c = candidates[i];
            final selected = c.identity.id == selectedId;
            return ListTile(
              dense: true,
              enabled: c.isCompatible,
              leading: Icon(
                c.isCompatible
                    ? (selected
                        ? LucideIcons.circleDot
                        : LucideIcons.circle)
                    : LucideIcons.minusCircle,
                color: c.isCompatible
                    ? (selected
                        ? AppColors.brandOrange
                        : AppColors.onSurfaceVariant)
                    : AppColors.onSurfaceDim,
                size: 18,
              ),
              title: RedactedText(Redactable.keyName(c.identity.label),
                  style: TextStyle(
                      fontSize: 13, color: AppColors.onSurface)),
              subtitle: Text(
                c.isCompatible
                    ? '${Redactable.username(c.identity.username).display} · '
                        '${_fingerprintOf(c.identity, l10n)}'
                    : l10n.certImportAlgorithmOrKeyMismatch,
                style: TextStyle(
                  fontSize: 11,
                  color: c.isCompatible
                      ? AppColors.onSurfaceVariant
                      : AppColors.onSurfaceDim,
                ),
              ),
              onTap: c.isCompatible ? () => onSelect(c.identity.id) : null,
            );
          },
        ),
      ),
    );
  }

  /// The identity's fingerprint in display form, or the literal fallback.
  String _fingerprintOf(Identity id, AppLocalizations l10n) {
    final fp = id.publicKeyFingerprint;
    if (fp == null || fp.isEmpty) return l10n.certImportNoFingerprint;
    return Redactable.fingerprint(fp).display;
  }
}

class _CertSummary extends ConsumerWidget {
  const _CertSummary({required this.cert});
  final SshCertificate cert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // The key id, principals and CA fingerprint identify the cert's subject
    // and issuer: masked while recording. The serial, the dates and the
    // algorithm are not identifiers.
    final keyId = Redactable.keyName(cert.keyId).displayIn(ref);
    final principals = cert.principals.isEmpty
        ? l10n.certImportPrincipalsAny
        : cert.principals
            .map((p) => Redactable.username(p).displayIn(ref))
            .join(',');
    final ca = Redactable.fingerprint(cert.caFingerprint).displayIn(ref);
    final exp = cert.validBeforeOrNull;
    final expired = exp != null && DateTime.now().toUtc().isAfter(exp);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: expired ? AppColors.error : AppColors.divider,
          width: expired ? 1.0 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                expired ? LucideIcons.alertCircle : LucideIcons.shieldCheck,
                size: 16,
                color: expired ? AppColors.error : AppColors.success,
              ),
              const SizedBox(width: 6),
              Text(
                expired
                    ? l10n.certImportExpired
                    : l10n.certImportValid,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: expired ? AppColors.error : AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _InfoRow(label: l10n.certImportLabelAlgorithm, value: cert.algorithm.name),
          _InfoRow(label: l10n.certImportLabelKeyId, value: keyId),
          _InfoRow(label: l10n.certImportLabelSerial, value: '0x${cert.serialHex}'),
          _InfoRow(label: l10n.certImportLabelPrincipals, value: principals),
          _InfoRow(
            label: l10n.certImportLabelValidAfter,
            value: cert.validAfterDateTime.toIso8601String(),
          ),
          _InfoRow(
            label: l10n.certImportLabelValidBefore,
            value: exp == null ? l10n.certImportNeverExpires : exp.toIso8601String(),
          ),
          _InfoRow(label: l10n.certImportLabelCa, value: ca),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceVariant,
                  fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'JetBrainsMono',
                  color: AppColors.onSurface),
            ),
          ),
        ],
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
                  CopyDetailsButton(
                      detail: ErrorReport.build(what: message, where: 'Importing a certificate', error: why)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

