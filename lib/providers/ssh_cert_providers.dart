import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_service.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';

/// Single shared [SshCertService] instance keyed off the secure-storage
/// provider. Re-built when secure storage swaps (e.g. test overrides).
final sshCertServiceProvider = Provider<SshCertService>((ref) {
  return SshCertService(
    ref.watch(secureStorageProvider),
    secrets: ref.watch(identitySecretsProvider),
    sealedBy: ref.watch(databaseSessionProvider),
  );
});

/// Stream of the cert (if any) attached to a given identity. Consumers
/// in the keys / identity-edit UI watch this so the chip badge updates
/// immediately after import / delete.
final certForIdentityProvider =
    FutureProvider.family<SshCertificate?, String>((ref, identityId) async {
  final svc = ref.watch(sshCertServiceProvider);
  return svc.loadCertForIdentity(identityId);
});
