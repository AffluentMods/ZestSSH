import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart' show IdentityEditScreen, InitialImportedKey;
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart' show DiscardChoice, showZestDiscardDialog;
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

/// Screen for generating new SSH key pairs.
///
/// Two-phase UX:
///  1. **Form phase** - key name, format, passphrase, comment, info card.
///  2. **Result phase** - fingerprint, copyable public key, share, instructions.
/// Algorithm hint passed to [KeyGenerationScreen.showAdaptive] so the
/// dialog opens with the right radio button pre-selected.  Callers
/// that don't care leave this null and the screen defaults to
/// Ed25519 (the recommended modern choice).
enum KeyGenerationFormatHint {
  ed25519,
  rsa,
  ecdsa,
}

class KeyGenerationScreen extends ConsumerStatefulWidget {
  const KeyGenerationScreen({super.key, this.initialFormat});

  /// Optional pre-selection - drives the format radio when the
  /// screen first opens.  Null means use the default (Ed25519).
  final KeyGenerationFormatHint? initialFormat;

  /// Show the pre-generation form as a dialog on desktop, route on mobile.
  ///
  /// Pass [initialFormat] to skip the "pick an algorithm" step - handy
  /// when the user invoked the action from a menu that already named
  /// the algorithm (e.g. "New SSH Key (Ed25519)").
  static Future<void> showAdaptive(
    BuildContext context, {
    KeyGenerationFormatHint? initialFormat,
  }) {
    final isWide = MediaQuery.of(context).size.width > 600;
    if (isWide) {
      return showDialog(
        context: context,
        builder: (ctx) => Dialog(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 500,
                maxHeight: 640,
              ),
              child: KeyGenerationScreen(initialFormat: initialFormat),
            ),
          ),
        ),
      );
    } else {
      // Mobile route doesn't carry the hint today - the route table
      // doesn't accept extras for this path.  Default to Ed25519 on
      // mobile, which is what the form already does in initState.
      return context.push(Routes.keyGeneration);
    }
  }

  @override
  ConsumerState<KeyGenerationScreen> createState() =>
      _KeyGenerationScreenState();
}

class _KeyGenerationScreenState extends ConsumerState<KeyGenerationScreen> {
  // ── Form state ───────────────────────────────────────────────────
  final _nameController = TextEditingController();
  final _commentController = TextEditingController();
  _KeyFormat _selectedFormat = _KeyFormat.ed25519;
  _KeyStrength _selectedStrength = _KeyStrength.rsa4096;
  bool _isGenerating = false;

  /// Whether the key generated is kept (saved as a key of the app, or let go
  /// on purpose): only then does this close without asking. It closed with
  /// the key handed to nobody, whatever was pressed, and the key was gone.
  bool _kept = false;

  // ── Result state ─────────────────────────────────────────────────
  String? _publicKeyString;
  String? _privateKeyPem;
  String? _fingerprint;
  bool _showResult = false;

  @override
  void initState() {
    super.initState();
    // Honor the initial-format hint from the caller.  Pre-selects
    // the radio + customises the default name so the user lands on
    // the algorithm they asked for.
    switch (widget.initialFormat) {
      case KeyGenerationFormatHint.rsa:
        _selectedFormat = _KeyFormat.rsa;
        _selectedStrength = _KeyStrength.rsa4096;
      case KeyGenerationFormatHint.ecdsa:
        _selectedFormat = _KeyFormat.ecdsa;
        _selectedStrength = _KeyStrength.ecdsaP256;
      case KeyGenerationFormatHint.ed25519:
      case null:
        _selectedFormat = _KeyFormat.ed25519;
    }
    _commentController.text = 'user@ZestSSH';
  }

  /// Whether the name has had its first default, in the person's language
  /// (it was English in every language: initState cannot read the
  /// language, so it is given here, once).
  bool _named = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_named) return;
    _named = true;
    final l10n = AppLocalizations.of(context)!;
    _nameController.text = switch (_selectedFormat) {
      _KeyFormat.rsa => l10n.keyGenDefaultNameRsa,
      _KeyFormat.ecdsa => l10n.keyGenDefaultNameEcdsa,
      _KeyFormat.ed25519 => l10n.keyGenDefaultNameEd25519,
    };
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  /// Resolve the selected format + strength into a KeyType.
  KeyType get _resolvedKeyType {
    return switch (_selectedFormat) {
      _KeyFormat.ed25519 => KeyType.ed25519,
      _KeyFormat.rsa => _selectedStrength == _KeyStrength.rsa2048
          ? KeyType.rsa2048
          : KeyType.rsa4096,
      _KeyFormat.ecdsa => switch (_selectedStrength) {
          _KeyStrength.ecdsaP256 => KeyType.ecdsaP256,
          _KeyStrength.ecdsaP384 => KeyType.ecdsaP384,
          _KeyStrength.ecdsaP521 => KeyType.ecdsaP521,
          _ => KeyType.ecdsaP256,
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      // A key generated and not kept is asked about before it goes.
      canPop: !_showResult || _kept,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_askBeforeLosing());
      },
      child: ResponsiveScaffold(
        title: _showResult ? l10n.keyGenResultTitle : l10n.keyGenTitle,
        body: _showResult ? _buildResultView(l10n) : _buildFormView(l10n),
      ),
    );
  }

  /// Save, Discard or Cancel, as every editor asks before what is not saved
  /// goes: Save keeps the key ([_save]), Discard closes without it.
  Future<void> _askBeforeLosing() async {
    final choice = await showZestDiscardDialog(context);
    if (!mounted) return;
    switch (choice) {
      case DiscardChoice.save:
        await _save();
      case DiscardChoice.discard:
        setState(() => _kept = true);
        Navigator.of(context).pop();
      case DiscardChoice.cancel:
        break;
    }
  }

  /// The key kept as a key of the app: the key form opens with it (its name,
  /// the key, its public line as shown here) for the user it signs in as;
  /// once that is saved this closes, with the new key's id. Cancelled there,
  /// the key is still here.
  Future<void> _save() async {
    final pem = _privateKeyPem;
    if (pem == null) return;
    final id = await IdentityEditScreen.showAdaptive(
      context,
      key: InitialImportedKey(
        privatePem: pem,
        fingerprint: _fingerprint ?? '',
        keyType: _resolvedKeyType.displayName,
        label: _nameController.text.trim(),
        publicKeyData: _publicKeyString,
      ),
    );
    if (id == null || !mounted) return;
    setState(() => _kept = true);
    Navigator.of(context).pop(id);
  }

  // ── Form Phase ───────────────────────────────────────────────────

  Widget _buildFormView(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── Key Name ─────────────────────────────────────────
        _SectionLabel(l10n.keyGenKeyName),
        const SizedBox(height: 8),
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            hintText: l10n.keyGenKeyNameHint,
            prefixIcon: const Icon(LucideIcons.tag, size: 20),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          textInputAction: TextInputAction.next,
        ),

        const SizedBox(height: 24),

        // ── Key Format ───────────────────────────────────────
        _SectionLabel(l10n.keyGenKeyType),
        const SizedBox(height: 8),
        ZestSelect<_KeyFormat>(
          key: const ValueKey('keygen-format'),
          value: _selectedFormat,
          items: [
            ZestSelectItem(_KeyFormat.ed25519, l10n.keyGenEd25519Recommended),
            ZestSelectItem(_KeyFormat.rsa, l10n.keyGenRsa),
            ZestSelectItem(_KeyFormat.ecdsa, l10n.keyGenEcdsa),
          ],
          onChanged: (v) {
            setState(() {
              _selectedFormat = v;
              if (v == _KeyFormat.rsa) {
                _selectedStrength = _KeyStrength.rsa4096;
                _nameController.text = l10n.keyGenDefaultNameRsa;
              } else if (v == _KeyFormat.ecdsa) {
                _selectedStrength = _KeyStrength.ecdsaP256;
                _nameController.text = l10n.keyGenDefaultNameEcdsa;
              } else {
                _nameController.text = l10n.keyGenDefaultNameEd25519;
              }
            });
          },
        ),

        // ── Key Strength (RSA / ECDSA only) ──────────────────
        if (_selectedFormat == _KeyFormat.rsa ||
            _selectedFormat == _KeyFormat.ecdsa) ...[
          const SizedBox(height: 16),
          _SectionLabel(l10n.identityKeyStrength),
          const SizedBox(height: 8),
          ZestSelect<_KeyStrength>(
            key: const ValueKey('keygen-strength'),
            value: _selectedStrength,
            items: _strengthOptionsForFormat(_selectedFormat),
            onChanged: (v) => setState(() => _selectedStrength = v),
          ),
        ],

        const SizedBox(height: 24),

        // ── Key Info Card ────────────────────────────────────
        _buildInfoCard(),

        const SizedBox(height: 24),

        // (A passphrase was asked here and locked nothing: the key is kept
        // where the app keeps its secrets, and it was handed on as it is.)

        // ── Comment ──────────────────────────────────────────
        _SectionLabel(l10n.keyGenComment),
        const SizedBox(height: 8),
        TextField(
          controller: _commentController,
          decoration: InputDecoration(
            hintText: l10n.keyGenCommentHint,
            prefixIcon: const Icon(LucideIcons.messageSquare, size: 20),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          textInputAction: TextInputAction.next,
        ),

        const SizedBox(height: 32),

        // ── Generate Button ──────────────────────────────────
        ButtonBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _isGenerating ? null : _generate,
            icon: _isGenerating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: ButtonSpinner(),
                  )
                : const Icon(LucideIcons.keyRound),
            label: Text(
              _isGenerating ? l10n.keyGenGenerating : l10n.keyGenGenerate,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              foregroundColor: AppColors.onBrand(AppColors.brandOrange),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Key details info card showing type, strength, and compatibility.
  Widget _buildInfoCard() {
    final l10n = AppLocalizations.of(context)!;
    final (strength, compat) = _keyInfoForFormat(_selectedFormat, _selectedStrength);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.brandOrange.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
        color: AppColors.brandOrange.withValues(alpha: 0.06),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info,
                  size: 18, color: AppColors.accentInk),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.keyGenKeyDetails,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentInk,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // The names in a column as wide as the longest (at least 100, at
          // most 55%): in 100, "Compatibility" was cut at 1.3 times the text
          // size, and in Portuguese and Russian at the size the app is drawn
          // at.
          Table(
            columnWidths: const {
              0: MinColumnWidth(
                  MaxColumnWidth(FixedColumnWidth(100), IntrinsicColumnWidth()), FractionColumnWidth(0.55)),
              1: FlexColumnWidth(),
            },
            children: [
              _infoRow(l10n.keyGenAlgorithm, _resolvedKeyType.displayName),
              _infoRow(l10n.keyGenStrength, strength),
              _infoRow(l10n.keyGenCompatibility, compat, last: true),
            ],
          ),
        ],
      ),
    );
  }

  // ── Result Phase ─────────────────────────────────────────────────

  Widget _buildResultView(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── Success banner ───────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(LucideIcons.checkCircle2, color: Colors.green, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.keyGenResultTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (_nameController.text.isNotEmpty)
                      Text(
                        _nameController.text,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // ── Fingerprint ──────────────────────────────────────
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.fingerprint,
                        color: AppColors.accentInk, size: 20),
                    const SizedBox(width: 8),
                    Text(l10n.keyGenFingerprint,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        )),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(
                  _fingerprint ?? '',
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ── Public Key ───────────────────────────────────────
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(l10n.keyGenPublicKey,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        )),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(LucideIcons.copy, size: 18),
                      tooltip: l10n.keyGenCopyPublicKey,
                      onPressed: _copyPublicKey,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _publicKeyString ?? '',
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // ── Action Buttons ───────────────────────────────────
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyPublicKey,
                icon: const Icon(LucideIcons.copy, size: 18),
                label: Text(l10n.keyGenCopyPublicKey),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _sharePublicKey,
                icon: const Icon(LucideIcons.share2, size: 18),
                label: Text(l10n.keyGenSharePublicKey),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // ── Instructions ─────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: AppColors.brandOrange.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppColors.brandOrange.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.lightbulb,
                      size: 18, color: AppColors.accentInk),
                  const SizedBox(width: 8),
                  Text(
                    l10n.keyGenNextSteps,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                l10n.keyGenInstructions,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Save / Use This Key ──────────────────────────────
        ButtonBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            key: const ValueKey('key-gen-save'),
            onPressed: _save,
            icon: const Icon(LucideIcons.save),
            label: Text(l10n.keyGenUseKey),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              foregroundColor: AppColors.onBrand(AppColors.brandOrange),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ── Done (go back; a key not kept is asked about first) ──
        ButtonBox(
          width: double.infinity,
          height: 44,
          child: TextButton(
            key: const ValueKey('key-gen-done'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(l10n.keyGenDone),
          ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  Future<void> _copyPublicKey() async {
    final l10n = AppLocalizations.of(context)!;
    // A key goes to the clipboard: reveal gate (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    Clipboard.setData(ClipboardData(text: _publicKeyString ?? ''));
    showTopSnackBar(context, l10n.keyGenPublicKeyCopied);
  }

  Future<void> _sharePublicKey() async {
    if (_publicKeyString == null) return;
    // A key goes to the share sheet: reveal gate (spec 5), like the copy.
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    await Share.share(_publicKeyString!);
  }

  (String strength, String compat) _keyInfoForFormat(
      _KeyFormat format, _KeyStrength strength) {
    final l10n = AppLocalizations.of(context)!;
    return switch (format) {
      _KeyFormat.ed25519 => (
          l10n.keyGenStrengthEd25519,
          l10n.keyGenCompatEd25519,
        ),
      _KeyFormat.rsa => switch (strength) {
          _KeyStrength.rsa2048 => (
              l10n.keyGenStrengthRsa2048,
              l10n.keyGenCompatRsaUniversal,
            ),
          _KeyStrength.rsa4096 => (
              l10n.keyGenStrengthRsa4096,
              l10n.keyGenCompatRsaUniversal,
            ),
          _ => (l10n.keyGenStrengthRsaFallback, l10n.keyGenCompatUniversal),
        },
      _KeyFormat.ecdsa => switch (strength) {
          _KeyStrength.ecdsaP256 => (
              l10n.keyGenStrengthEcdsaP256,
              l10n.keyGenCompatEcdsa,
            ),
          _KeyStrength.ecdsaP384 => (
              l10n.keyGenStrengthEcdsaP384,
              l10n.keyGenCompatEcdsa,
            ),
          _KeyStrength.ecdsaP521 => (
              l10n.keyGenStrengthEcdsaP521,
              l10n.keyGenCompatEcdsa,
            ),
          _ => (l10n.keyGenStrengthEcdsaFallback, l10n.keyGenCompatEcdsaFallback),
        },
    };
  }

  List<ZestSelectItem<_KeyStrength>> _strengthOptionsForFormat(
      _KeyFormat format) {
    final l10n = AppLocalizations.of(context)!;
    return switch (format) {
      _KeyFormat.rsa => [
          ZestSelectItem(_KeyStrength.rsa2048, l10n.keyGenRsa2048Bits),
          ZestSelectItem(_KeyStrength.rsa4096, l10n.keyGenRsa4096Recommended),
        ],
      _KeyFormat.ecdsa => [
          ZestSelectItem(_KeyStrength.ecdsaP256, l10n.keyGenEcdsaP256Nist),
          ZestSelectItem(_KeyStrength.ecdsaP384, l10n.keyGenEcdsaP384Nist),
          ZestSelectItem(_KeyStrength.ecdsaP521, l10n.keyGenEcdsaP521Nist),
        ],
      _ => const [],
    };
  }

  Future<void> _generate() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isGenerating = true);

    try {
      final keyGen = ref.read(keyGenerationServiceProvider);
      final comment = _commentController.text.trim().isNotEmpty
          ? _commentController.text.trim()
          : l10n.keyGenFallbackComment;
      final result = await keyGen.generate(
        _resolvedKeyType,
        comment: comment,
      );

      if (!mounted) return;
      setState(() {
        _publicKeyString = result.publicOpenSSH;
        _privateKeyPem = result.privatePem;
        _fingerprint = result.fingerprint;
        _showResult = true;
      });
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.keyNotGenerated,
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }
}

// ── Reusable widgets ──────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    );
  }
}

/// A name and its value in the key's details.
TableRow _infoRow(String label, String value, {bool last = false}) {
  final below = EdgeInsets.only(bottom: last ? 0 : 6);
  return TableRow(children: [
    Padding(
      padding: below.copyWith(right: 12),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
      ),
    ),
    Padding(
      padding: below,
      child: Text(
        value,
        style: const TextStyle(fontSize: 13),
      ),
    ),
  ]);
}

// ── Key format & strength enums ─────────────────────────────────

enum _KeyFormat { ed25519, rsa, ecdsa }

enum _KeyStrength { rsa2048, rsa4096, ecdsaP256, ecdsaP384, ecdsaP521 }
