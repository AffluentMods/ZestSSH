import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// A stand-in for a key's commitment in record tests that never open the
/// key: 32 bytes derived from [seed], as base64. The record checks only its
/// shape; a device checks a key it opens against the real commitment
/// (keyCommitment in orchard_crypto.dart).
String testCommit(Object? seed) => base64Encode(sha256.convert(utf8.encode('test-commit:$seed')).bytes);
