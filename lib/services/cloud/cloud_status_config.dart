import 'dart:convert';

import 'package:zestssh/services/cloud/cloud_statement.dart';

/// Where the ZestSSH status service is, and the public halves of the keys
/// it signs with (3.0). The service is a Cloudflare Worker that runs apart
/// from ZestSSH Cloud (infra/status_worker; its README says how it is put
/// up and how its keys are made).
///
/// EMPTY UNTIL THE SERVICE IS PUT UP. With no address or no key nothing is
/// asked and nothing is believed, and the app says what one device can know
/// by itself ("ZestSSH Cloud is not responding"). To switch it on: put the
/// address of the service's one question here (its host, then `/v1/now`,
/// over https), and the PUBLIC line of each of its two keys, as
/// `tool/make_keys.mjs` printed them (the name, then 32 bytes in base64).
/// Public keys are not secret. The private halves never come near this
/// repository.
const String kCloudStatusUrl = '';

/// The public halves of the keys that may sign a statement, by name.
const Map<String, String> kCloudStatusKeys = {};

/// The status service as a build is set up for it: [url], the host a
/// statement must be about ([service]), and [keys] (the name of each to its
/// 32 public bytes in base64). A key that is not 32 bytes in base64 is no
/// key and is left out; with none left, nothing is asked.
CloudStatusConfig cloudStatusConfigOf({
  required String url,
  required String service,
  required Map<String, String> keys,
}) {
  final read = <String, List<int>>{};
  for (final MapEntry(key: name, value: text) in keys.entries) {
    try {
      final bytes = base64Decode(text.trim());
      if (bytes.length == 32) read[name] = bytes;
    } on FormatException {
      // No key.
    }
  }
  return CloudStatusConfig(url: url.trim(), service: service, keys: read);
}
