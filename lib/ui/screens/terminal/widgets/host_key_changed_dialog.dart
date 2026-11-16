import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/terminal/widgets/team_pin_choice.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/host_address.dart';

/// Asks whether to trust [verification]'s host key: the changed-key warning
/// ([HostKeyChangedDialog]) or a new host's question ([NewHostKeyDialog]), as
/// the app's dialog (a phone's sheet). True to trust, false not to; null
/// where it was taken away unanswered (its page replaced, the lock screen
/// shown), which leaves the key to be asked about again. Escape and a tap
/// outside leave it, as every answer is a button (the close button is the
/// safe one: do not trust).
Future<bool?> askHostKeyTrust(BuildContext context, HostKeyVerification verification) {
  return showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: verification.isChanged
        ? HostKeyChangedDialog(verification: verification)
        : NewHostKeyDialog(verification: verification),
  );
}

/// A host's key, or a server's certificate, on the first connection to it
/// (4.0 UI):
/// the server named in the title (it said "New host key"), one line
/// on why it asks, the key's type and its SHA256 fingerprint in groups of
/// four with a copy button that copies it whole (it was one unbroken
/// string), the command that prints it on the server with a copy button
/// (only the changed key's question had it), and the other way to check it;
/// Reject, or Trust and connect (it said "Accept & save", and connected too).
/// An FTPS server's certificate and a remote screen's the same, in their
/// words, with openssl's command. While recording mode is on, the fixed fake
/// fingerprint with its reveal, and no copy. On a computer and on a phone
/// alike (a phone's as a sheet). No other choice than before is offered.
class NewHostKeyDialog extends ConsumerWidget {
  const NewHostKeyDialog({super.key, required this.verification});

  final HostKeyVerification verification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final v = verification;
    final certificate = v.certificate;
    // Where: the server's address, with its port where it is not SSH's 22.
    final address = Redactable.address(
            !certificate && v.port == 22 ? bracketIpv6(v.host) : hostWithPort(v.host, v.port))
        .displayIn(ref);
    // The saved host it is of, where its address does not say which (a
    // remote screen at localhost:5900 through another host): its name in the
    // title, its address under it.
    final name = v.name == null ? null : Redactable.host(v.name!).displayIn(ref);
    final why = v.screen
        ? (v.via == null
            ? l10n.screenCertificateFirstWhy
            : l10n.screenCertificateFirstWhyVia(Redactable.host(v.via!).displayIn(ref)))
        : certificate
            ? l10n.ftpsCertificateFirstWhy
            : l10n.hostKeyFirstWhy;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: certificate ? LucideIcons.fileBadge : LucideIcons.keyRound,
      title: l10n.hostKeyFirstTitle(name ?? address),
      subtitle: name == null ? null : address,
      maxWidth: 520,
      onClose: () => Navigator.of(context).pop(false),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            why,
            key: const ValueKey('host-key-new'),
            style: TextStyle(fontSize: 13.5, height: 1.5, color: ZestTokens.textSecondary),
          ),
          const SizedBox(height: 16),
          FirstConnectionFingerprint(verification: v),
          const SizedBox(height: 16),
          Text(
            l10n.hostKeyCheckOnServer,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary),
          ),
          const SizedBox(height: 7),
          _CopyLine(
            key: const ValueKey('host-key-new-command'),
            text: hostKeyCheckCommand(v.keyType),
            tooltip: l10n.hostKeyChangedCopyCommand,
            copied: l10n.hostKeyChangedCommandCopied,
          ),
          const SizedBox(height: 10),
          Text(
            certificate ? l10n.certificateCompareOwner : l10n.hostKeyCompareProvider,
            key: const ValueKey('host-key-new-other-way'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary),
          ),
          TeamPinChoice(verification: v),
        ],
      ),
      secondaryKey: const ValueKey('host-key-new-reject'),
      secondaryAction: (label: l10n.terminalReject, onPressed: () => Navigator.of(context).pop(false)),
      primaryKey: const ValueKey('host-key-new-trust'),
      primaryAction: (
        label: l10n.hostKeyTrustAndConnect,
        icon: null,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    );
  }
}

/// [fingerprint] as the first connection's question shows it, to be read
/// and compared: an SSH key's SHA256 in groups of four, six to a line (its
/// 43 characters on two lines), and a certificate's SHA-256 as openssl
/// prints it, eight bytes to a line. Anything else as it is.
String groupedFingerprint(String fingerprint) {
  final shown = fingerprintAsShown(fingerprint);
  if (shown.startsWith('SHA256:')) {
    final body = shown.substring('SHA256:'.length);
    final groups = [for (var i = 0; i < body.length; i += 4) body.substring(i, math.min(i + 4, body.length))];
    return [
      for (var i = 0; i < groups.length; i += 6) groups.sublist(i, math.min(i + 6, groups.length)).join(' '),
    ].join('\n');
  }
  final bytes = shown.split(':');
  if (bytes.length > 1 && bytes.every((b) => RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(b))) {
    return [
      for (var i = 0; i < bytes.length; i += 8) bytes.sublist(i, math.min(i + 8, bytes.length)).join(':'),
    ].join('\n');
  }
  return shown;
}

/// A host key's type as the first connection's question names it (ED25519,
/// RSA, ECDSA P-256), and a certificate's (X.509).
String hostKeyTypeLabel(String keyType) => switch (keyType) {
      'ssh-ed25519' => 'ED25519',
      'ssh-ed448' => 'ED448',
      'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'RSA',
      'ecdsa-sha2-nistp256' => 'ECDSA P-256',
      'ecdsa-sha2-nistp384' => 'ECDSA P-384',
      'ecdsa-sha2-nistp521' => 'ECDSA P-521',
      'ssh-dss' => 'DSA',
      KnownHostsService.certificateKeyType => 'X.509',
      _ => keyType.toUpperCase(),
    };

/// A correct, general command to run ON the server, which prints its OWN
/// host key's fingerprint for comparing out of band: the public key file
/// of the key's type; for anything unusual, every host key's fingerprint.
/// An FTPS server's or a remote screen's certificate: openssl's, of the
/// certificate file the server is set up with.
String hostKeyCheckCommand(String keyType) {
  if (keyType == KnownHostsService.certificateKeyType) {
    return 'openssl x509 -noout -fingerprint -sha256 -in /path/to/certificate.pem';
  }
  final String? file;
  if (keyType == 'ssh-ed25519') {
    file = 'ssh_host_ed25519_key.pub';
  } else if (keyType == 'ssh-rsa' || keyType == 'rsa-sha2-256' || keyType == 'rsa-sha2-512') {
    file = 'ssh_host_rsa_key.pub';
  } else if (keyType.startsWith('ecdsa-')) {
    file = 'ssh_host_ecdsa_key.pub';
  } else {
    file = null;
  }
  if (file == null) {
    return 'for f in /etc/ssh/ssh_host_*_key.pub; '
        'do ssh-keygen -lf "\$f"; done';
  }
  return 'ssh-keygen -lf /etc/ssh/$file';
}

/// A first connection's fingerprint: the key's type and what the fingerprint
/// is, a copy button (the fingerprint whole, SHA256:... with no spaces), and
/// the fingerprint in groups ([groupedFingerprint]), large enough to read
/// aloud. While recording mode is on, the fixed fake (the length of a real
/// SHA256) with the reveal, and nothing to copy.
class FirstConnectionFingerprint extends ConsumerWidget {
  const FirstConnectionFingerprint({super.key, required this.verification});

  final HostKeyVerification verification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final recording = ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final v = verification;
    final shown = recording ? Redactable.fingerprint(v.fingerprint).display : v.fingerprint;
    return Container(
      key: const ValueKey('host-key-new-fingerprint'),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                key: const ValueKey('host-key-new-type'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceChip,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: ZestTokens.border),
                ),
                child: Text(
                  hostKeyTypeLabel(v.keyType),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: ZestTokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  v.certificate ? l10n.certificateFingerprintLabel : l10n.hostKeyFingerprintLabel,
                  style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                ),
              ),
              if (recording)
                // An icon on the fingerprint (the dialog rules, 3.4: no
                // button in a dialog's body).
                IconButton(
                  key: const ValueKey('host-key-fingerprint-reveal'),
                  tooltip: l10n.recModeRevealAction,
                  iconSize: 16,
                  color: ZestTokens.textSecondary,
                  onPressed: () => confirmRevealWhileRecording(context, ref),
                  icon: const Icon(LucideIcons.eye),
                )
              else
                IconButton(
                  key: const ValueKey('host-key-new-copy'),
                  tooltip: l10n.hostKeyCopyFingerprint,
                  iconSize: 16,
                  color: ZestTokens.textSecondary,
                  onPressed: () {
                    // A fingerprint is public: the plain clipboard.
                    Clipboard.setData(ClipboardData(text: fingerprintAsShown(v.fingerprint)));
                    showTopSnackBar(context, l10n.hostKeyFingerprintCopied, isSuccess: true);
                  },
                  icon: const Icon(LucideIcons.copy),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: SelectableText(
              groupedFingerprint(shown),
              key: const ValueKey('host-key-new-groups'),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 16,
                height: 1.65,
                letterSpacing: 0.3,
                wordSpacing: 4,
                color: ZestTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A line to copy (the command that prints the fingerprint on the server),
/// in the app's monospace, with its copy button.
class _CopyLine extends StatelessWidget {
  const _CopyLine({super.key, required this.text, required this.tooltip, required this.copied});

  final String text;
  final String tooltip;
  final String copied;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                text,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.4, color: ZestTokens.textPrimary),
              ),
            ),
          ),
          IconButton(
            tooltip: tooltip,
            iconSize: 16,
            color: ZestTokens.textSecondary,
            icon: const Icon(LucideIcons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              showTopSnackBar(context, copied, isSuccess: true);
            },
          ),
        ],
      ),
    );
  }
}

/// Security-critical warning shown when an already-trusted host presents a
/// DIFFERENT host key than the one on record (Doc-3 F2).
///
/// Deliberately distinct from the routine first-connection prompt:
/// * warning visual treatment (error/warning tone + warning icon);
/// * shows BOTH fingerprints - the Expected (stored) one and the Received one;
/// * shows when the expected key was trusted;
/// * explains the benign AND the malicious causes, proportionately;
/// * offers a copyable command to verify the key ON the server itself;
/// * INVERTS the actions vs the first-connection prompt - Cancel/Disconnect is
///   the prominent, autofocused primary; "Trust new key" is the quiet,
///   deliberate secondary (Enter never trusts).
///
/// Recording mode: the host in the banner is masked and both fingerprints
/// show the fixed fake with a Reveal button ([HostKeyFingerprint]), since
/// verifying a key needs the real digest and the reveal gate only proceeds by
/// turning the mode off.
///
/// Returns `true` from the dialog only when the user explicitly chose to trust
/// the new key; `false` (or a barrier dismissal, which callers coerce to
/// `false`) aborts the connection.
class HostKeyChangedDialog extends ConsumerWidget {
  const HostKeyChangedDialog({super.key, required this.verification});

  final HostKeyVerification verification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final expected = verification.expectedFingerprint;
    final trustedAt = verification.expectedTrustedAt;
    final command = hostKeyCheckCommand(verification.keyType);
    final target =
        Redactable.address(hostWithPort(verification.host, verification.port))
            .displayIn(ref);
    // The team pinned another key here: only someone who
    // may edit the pin's Crate can replace it, for everyone.
    final team = verification.teamPin;
    final teamPinned = team != null && team.pinned;
    final mayTrust = !teamPinned || team.mayChange;

    // The app's dialog (the dialog rules, 3.4): red for what it means (a key
    // that is not the one trusted), the warning in its amber sentence, and
    // one footer. Its body scrolls, so nothing is clipped on a short phone
    // or a small window.
    return ZestDialogShell(
      tone: ZestDialogTone.destructive,
      icon: LucideIcons.alertTriangle,
      title: teamPinned
          ? (verification.certificate ? l10n.teamCertificateMismatchTitle : l10n.teamHostKeyMismatchTitle)
          : verification.certificate
              ? l10n.ftpsCertificateChangedTitle
              : l10n.hostKeyChangedTitle,
      maxWidth: 520,
      // The close button is the safe answer: do not trust.
      onClose: () => Navigator.of(context).pop(false),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── The warning: benign causes first, malicious not buried ──
          ZestCallout(
            teamPinned
                ? (verification.certificate
                    ? l10n.teamCertificateMismatchBanner(target, team.crateName)
                    : l10n.teamHostKeyMismatchBanner(target, team.crateName))
                : verification.certificate
                    ? l10n.ftpsCertificateChangedBanner(target)
                    : l10n.hostKeyChangedBanner(target),
            key: ValueKey(teamPinned ? 'team-pin-mismatch' : 'host-key-changed'),
          ),
          const SizedBox(height: 16),

          // ── Expected (stored/trusted) fingerprint ──
          Text(
            teamPinned
                ? l10n.teamHostKeyPinnedLabel
                : trustedAt != null
                    ? l10n.hostKeyChangedExpectedTrusted(_formatTrustDate(trustedAt))
                    : l10n.hostKeyChangedExpectedUnknownDate,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 4),
          if (expected != null)
            HostKeyFingerprint(fingerprint: expected)
          else
            Text(
              l10n.hostKeyChangedExpectedUnknownKey,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: AppColors.v3TextSecondary,
              ),
            ),
          const SizedBox(height: 12),

          // ── Received (new) fingerprint: red, the key that is not the one
          // trusted ──
          Text(
            l10n.hostKeyChangedReceived,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: AppColors.v3Error,
            ),
          ),
          const SizedBox(height: 4),
          HostKeyFingerprint(
            fingerprint: verification.fingerprint,
            danger: true,
          ),
          const SizedBox(height: 16),

          // ── Out-of-band verification command ──
          Text(
            l10n.hostKeyChangedVerifyHint,
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 6),
          _CommandBox(command: command),
          const SizedBox(height: 16),

          // ── Permanent-replace note ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  teamPinned
                      ? (team.mayChange
                          ? (verification.certificate
                              ? l10n.teamCertificateReplaceNote(team.crateName)
                              : l10n.teamHostKeyReplaceNote(team.crateName))
                          : (verification.certificate
                              ? l10n.teamCertificateAskEditor(team.crateName)
                              : l10n.teamHostKeyAskEditor(team.crateName)))
                      : verification.certificate
                          ? l10n.ftpsCertificateChangedPermanentNote
                          : l10n.hostKeyChangedPermanentNote,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.v3TextSecondary,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          TeamPinChoice(verification: verification),
        ],
      ),
      // Actions INVERTED vs the first-connection prompt: Cancel/Disconnect is
      // the prominent, autofocused main button (so muscle-memory and Enter
      // both hit the SAFE choice), in the brand's colour; trusting the new key
      // is the red outlined button beside it, chosen deliberately.
      secondaryKey: const ValueKey('host-key-changed-trust'),
      secondaryDanger: true,
      secondaryAction: mayTrust
          ? (
              label: teamPinned
                  ? (verification.certificate ? l10n.teamCertificateReplace : l10n.teamHostKeyReplace)
                  : verification.certificate
                      ? l10n.ftpsCertificateChangedTrust
                      : l10n.hostKeyChangedTrust,
              onPressed: () => Navigator.of(context).pop(true),
            )
          : null,
      primaryKey: const ValueKey('host-key-changed-cancel'),
      primaryBrand: true,
      autofocusPrimary: true,
      primaryAction: (
        label: l10n.hostKeyChangedCancel,
        icon: null,
        onPressed: () => Navigator.of(context).pop(false),
      ),
    );
  }

  /// Format a trust timestamp compactly in local time (yyyy-MM-dd HH:mm).
  static String _formatTrustDate(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

/// A full, selectable, monospace fingerprint block.
///
/// While recording mode is on it paints the fixed fake (the length of a real
/// SHA256, decoding to `REDACTED-BY-ZESTSSH-REC-MODE`) and a Reveal button
/// that runs the reveal gate: the gate turns the mode off, this rebuilds with
/// the real digest, and the user can verify the key. The desktop and mobile
/// host-key prompts and the changed-key warning all use it.
class HostKeyFingerprint extends ConsumerWidget {
  const HostKeyFingerprint({
    super.key,
    required this.fingerprint,
    this.danger = false,
  });

  final String fingerprint;
  final bool danger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    const style = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: danger
            ? AppColors.v3Error.withValues(alpha: 0.08)
            : AppColors.v3Surface,
        borderRadius: BorderRadius.circular(6),
        border: danger
            ? Border.all(color: AppColors.v3Error.withValues(alpha: 0.25))
            : Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: recording
          ? Row(
              children: [
                Expanded(
                  child: Text(
                    Redactable.fingerprint(fingerprint).display,
                    style: style,
                  ),
                ),
                // An icon on the fingerprint (the dialog rules, 3.4: no
                // button in a dialog's body).
                IconButton(
                  key: const ValueKey('host-key-fingerprint-reveal'),
                  tooltip: AppLocalizations.of(context)!.recModeRevealAction,
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  color: AppColors.v3TextSecondary,
                  onPressed: () => confirmRevealWhileRecording(context, ref),
                  icon: const Icon(LucideIcons.eye),
                ),
              ],
            )
          : SelectableText(fingerprint, style: style),
    );
  }
}

/// The copyable out-of-band verify command.
class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
            ),
          ),
          IconButton(
            tooltip: l10n.hostKeyChangedCopyCommand,
            icon: const Icon(LucideIcons.copy, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: command));
              final messenger = ScaffoldMessenger.maybeOf(context);
              messenger?.showSnackBar(
                SnackBar(
                  content: Text(l10n.hostKeyChangedCommandCopied),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
