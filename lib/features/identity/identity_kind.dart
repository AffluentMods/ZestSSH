import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Whether [id] signs in with a password, kept here or in a password
/// manager, rather than with a key of some kind (a key, a certificate, a
/// team's certificate, an agent's key). The one split of a phone's list and
/// a computer's (whose Passwords section holds the same two).
bool isPasswordIdentity(Identity id) => id.authMethod == 'password' || id.authMethod == 'passwordManager';

/// A key's algorithm as a list names it, or the word for a key where it has
/// none.
String keyTypeLabel(AppLocalizations l10n, String? keyType) {
  if (keyType == null || keyType.isEmpty) return l10n.homeKeyTypeFallback;
  final lower = keyType.toLowerCase();
  if (lower.contains('ed25519')) return 'Ed25519';
  if (lower.contains('ecdsa')) return 'ECDSA';
  if (lower.contains('rsa')) return 'RSA';
  if (lower.contains('dsa')) return 'DSA';
  return keyType;
}

/// What kind of sign-in [id] is, as a phone's list and a computer's name it:
/// a password, a certificate, an agent's key (and whose agent), a team's
/// certificate, a password manager's, or a key by its algorithm.
String identityTypeLabel(AppLocalizations l10n, Identity id) => switch (id.authMethod) {
      'password' => l10n.identityPassword,
      'certificate' => l10n.identityCertificate,
      // Whose agent (3.0).
      'hardwareToken' => switch (id.agentSource) {
          '1password' => l10n.identityAgentKeyOf('1Password'),
          'bitwarden' => l10n.identityAgentKeyOf('Bitwarden'),
          _ => l10n.identityAgentKey,
        },
      'teamCertificate' => l10n.identityTeamCertificate,
      'passwordManager' => l10n.pmKeyTypeLabel,
      _ => keyTypeLabel(l10n, id.keyType),
    };
