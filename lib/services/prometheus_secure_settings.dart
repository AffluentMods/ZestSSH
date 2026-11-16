import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/secret_seal.dart';

/// The monitoring server's sign-in, in the system's secure storage. Its
/// secrets (the client certificate and its password, a bearer token, a
/// password, a header's value) are sealed while the encrypting lock is on
/// (SecretSeal; 22 October 2026: they were kept as they were); the CA
/// certificate and the user name are not secrets and are kept as they are.
class PrometheusSecureSettings {
  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps the secrets; none while the app
  /// is locked, when a sealed one reads as none.
  final AppDatabase? Function() _tree;

  static const _prefix = 'prometheus_';

  PrometheusSecureSettings(this._storage, {AppDatabase? Function()? tree})
      : _tree = tree ?? (() => SecretSeal.openTree);

  Future<String?> _read(String name) async {
    final slot = '$_prefix$name';
    return openKept(_tree(), slot, await _storage.read(key: slot));
  }

  Future<void> _write(String name, String? value) async {
    final slot = '$_prefix$name';
    if (value == null) return _storage.delete(key: slot);
    await _storage.write(key: slot, value: await keepSealed(_tree(), slot, value));
  }

  // --- CA PEM ---
  Future<String?> getCaPem() => _read('ca_pem');
  Future<void> setCaPem(String? pem) => _write('ca_pem', pem);

  Future<bool> hasCaPem() async => (await getCaPem()) != null;

  // --- Client Cert P12 (stored as base64) ---
  Future<Uint8List?> getClientCertP12Bytes() async {
    final b64 = await _read('client_cert_p12');
    if (b64 == null) return null;
    return base64Decode(b64);
  }

  Future<bool> hasClientCert() async => (await getClientCertP12Bytes()) != null;

  Future<void> setClientCertP12Bytes(Uint8List? bytes) =>
      _write('client_cert_p12', bytes == null ? null : base64Encode(bytes));

  // --- Client Cert Password ---
  Future<String?> getClientCertPassword() => _read('client_cert_pass');
  Future<void> setClientCertPassword(String? password) => _write('client_cert_pass', password);

  // --- Bearer Token ---
  Future<String?> getBearerToken() => _read('bearer_token');
  Future<void> setBearerToken(String? token) => _write('bearer_token', token);

  // --- Basic Auth User ---
  Future<String?> getBasicAuthUser() => _read('basic_user');
  Future<void> setBasicAuthUser(String? user) => _write('basic_user', user);

  // --- Basic Auth Password ---
  Future<String?> getBasicAuthPassword() => _read('basic_pass');
  Future<void> setBasicAuthPassword(String? password) => _write('basic_pass', password);

  // --- Custom Header Value ---
  Future<String?> getCustomHeaderValue() => _read('custom_header_val');
  Future<void> setCustomHeaderValue(String? value) => _write('custom_header_val', value);
}
