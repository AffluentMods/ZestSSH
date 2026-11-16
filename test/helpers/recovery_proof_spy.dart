import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:zestssh/services/account/recovery_proof.dart';

/// A recovery proof service that only notes the keys it was asked to
/// register with: nothing is sent anywhere.
class RecoveryProofSpy extends RecoveryProofService {
  RecoveryProofSpy()
      : super(
          api: () => throw StateError('a test registers nothing'),
          accountUid: () async => 'u1',
          hosted: () => true,
        );

  /// The keys, in the order asked.
  final asked = <SecretKey>[];

  @override
  Future<void> register(SecretKey mek) async => asked.add(mek);
}
