import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/services/own_network_http.dart' show isOwnNetworkHost;
import 'package:zestssh/services/secret_seal.dart';

// Where an Orchard's events go (3.0), and the key they are signed
// with: kept on the one device that sends them, in the system's secure
// storage, in no sync and no backup. Neither ZestSSH Cloud nor another
// member ever sees the address or what unlocks it; the Orchard's record
// holds only the public half of the key.

/// Why an address cannot be one to send events to.
enum ExportAddressProblem {
  /// Nothing was given.
  empty,

  /// Not an address with a host in it, or too long.
  notAnAddress,

  /// Plain http to an address that is not on the person's own network (the
  /// app's one rule for requests that carry a secret: own_network_http.dart).
  notSecure,
}

/// Why a header cannot be sent along.
enum ExportHeaderProblem {
  /// A name without a value, or a value without a name.
  half,

  /// A name that is not a header's name, or one the request sets itself.
  name,

  /// A value with a line end or another character a header cannot carry,
  /// or too long.
  value,
}

/// Where events are sent: an address, how a request's body is laid out,
/// and one header to send along (what a collector asks for to take them, a
/// token most often), or none.
class ExportDestination {
  const ExportDestination({required this.url, this.format = ExportFormat.lines, this.headerName, this.headerValue});

  final Uri url;
  final ExportFormat format;
  final String? headerName;
  final String? headerValue;

  static const maxAddress = 2048;
  static const maxHeaderName = 64;
  static const maxHeaderValue = 4096;

  /// Names the request sets itself, in small letters.
  static const ownHeaders = {'content-type', 'content-length', 'host', 'transfer-encoding', 'connection'};

  static final _headerName = RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$");

  /// Printable ASCII and spaces, which is what a header carries: no line
  /// ends, no control characters.
  static final _headerValue = RegExp(r'^[\x20-\x7E]*$');

  /// The address [text] names, or why it is not one to send events to.
  static ({Uri? url, ExportAddressProblem? problem}) address(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return (url: null, problem: ExportAddressProblem.empty);
    // (A space in it, which the parser would take as part of a name, is
    // never part of an address.)
    final url = trimmed.length > maxAddress || trimmed.contains(RegExp(r'\s')) ? null : Uri.tryParse(trimmed);
    if (url == null || url.host.isEmpty || url.hasFragment || !(url.isScheme('https') || url.isScheme('http'))) {
      return (url: null, problem: ExportAddressProblem.notAnAddress);
    }
    if (url.isScheme('http') && !isOwnNetworkHost(url.host)) {
      return (url: null, problem: ExportAddressProblem.notSecure);
    }
    return (url: url, problem: null);
  }

  /// Why [name] and [value] cannot be sent along as a header, or null:
  /// both or neither, a header's name that is not one the request sets
  /// itself, and a value on one line.
  static ExportHeaderProblem? header(String? name, String? value) {
    final n = name?.trim() ?? '';
    final v = value?.trim() ?? '';
    if (n.isEmpty && v.isEmpty) return null;
    if (n.isEmpty || v.isEmpty) return ExportHeaderProblem.half;
    if (n.length > maxHeaderName || !_headerName.hasMatch(n) || ownHeaders.contains(n.toLowerCase())) {
      return ExportHeaderProblem.name;
    }
    if (v.length > maxHeaderValue || !_headerValue.hasMatch(v)) return ExportHeaderProblem.value;
    return null;
  }

  /// A destination from what a person typed, or null when [address] or
  /// [header] refuses it. Spaces around each are dropped.
  static ExportDestination? of(String addressText, ExportFormat format, {String? headerName, String? headerValue}) {
    final a = address(addressText);
    if (a.url == null || header(headerName, headerValue) != null) return null;
    final n = headerName?.trim() ?? '';
    return ExportDestination(
      url: a.url!,
      format: format,
      headerName: n.isEmpty ? null : n,
      headerValue: n.isEmpty ? null : headerValue!.trim(),
    );
  }

  /// The headers of a request to it.
  Map<String, String> get headers => {
        'Content-Type': format.contentType,
        if (headerName != null && headerValue != null) headerName!: headerValue!,
      };

  Map<String, Object?> toJson() => {
        'url': url.toString(),
        'format': format.id,
        'header_name': ?headerName,
        'header_value': ?headerValue,
      };

  /// Read back from [toJson]'s JSON; null for anything that is not one a
  /// person could have set up.
  static ExportDestination? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'], name = json['header_name'], value = json['header_value'];
    final format = ExportFormat.of(json['format']);
    if (url is! String || format == null || (name != null && name is! String) || (value != null && value is! String)) {
      return null;
    }
    return of(url, format, headerName: name as String?, headerValue: value as String?);
  }
}

/// What the sending device keeps for one Orchard: the private half of the
/// key the record names ([seed], 32 bytes), where the events go, and the
/// last note of activity there was when sending was set up ([activityFrom],
/// its id): what members did before that is not sent.
class ExportSettings {
  const ExportSettings({required this.seed, required this.destination, required this.activityFrom});

  final Uint8List seed;
  final ExportDestination destination;
  final int activityFrom;

  String toText() => jsonEncode({
        'v': 1,
        'seed': base64Encode(seed),
        'to': destination.toJson(),
        'activity_from': activityFrom,
      });

  /// Read back from [toText]; null for anything else.
  static ExportSettings? fromText(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['v'] != 1) return null;
      final seed = json['seed'], from = json['activity_from'];
      final to = ExportDestination.fromJson(json['to']);
      if (seed is! String || from is! int || from < 0 || to == null) return null;
      final bytes = base64Decode(seed);
      if (bytes.length != 32) return null;
      return ExportSettings(seed: bytes, destination: to, activityFrom: from);
    } on FormatException {
      return null;
    }
  }
}

/// Where a device keeps what it sends an Orchard's events with: the
/// system's secure storage, one entry for each account and Orchard, and one
/// for each account that lists the Orchards it has an entry for (so the
/// device knows where it sends without asking about every Orchard). Beside
/// each entry, a note of how far the device got.
///
/// All three are sealed while the encrypting lock is on (SecretSeal; before,
/// the entry, with the key events are sent with, was kept as
/// it was). While the app is locked a sealed one reads as none.
class ExportSettingsStore {
  ExportSettingsStore(this._storage, {AppDatabase? Function()? tree}) : _tree = tree ?? (() => SecretSeal.openTree);

  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps the entries; none while the app
  /// is locked.
  final AppDatabase? Function() _tree;

  Future<String?> _read(String slot) async => openKept(_tree(), slot, await _storage.read(key: slot));

  Future<void> _write(String slot, String value) async =>
      _storage.write(key: slot, value: await keepSealed(_tree(), slot, value));

  /// The entry of the account [uid] for [orchardId].
  static String storageKey(String uid, String orchardId) => 'orchard_export_v1.$uid.$orchardId';

  /// The note of how far the device got with [orchardId]'s events. The
  /// Orchard's database keeps that too; this note outlives it.
  static String sentKey(String uid, String orchardId) => '${storageKey(uid, orchardId)}.sent';

  /// The entry that lists the Orchards [uid] has settings for.
  static String listKey(String uid) => 'orchard_export_v1.$uid';

  /// The Orchards this device keeps settings for, for the account [uid].
  Future<Set<String>> orchards(String uid) => _orchards(uid, strict: false);

  /// [orchards]; [strict], a sealed list that does not open throws
  /// ([SecretSealBroken]), so a change made from it never drops the
  /// Orchards it could not read.
  Future<Set<String>> _orchards(String uid, {required bool strict}) async {
    final slot = listKey(uid);
    final kept = await _storage.read(key: slot);
    final raw = strict ? await openKeptOrThrow(_tree(), slot, kept) : await openKept(_tree(), slot, kept);
    if (raw == null) return {};
    try {
      final list = jsonDecode(raw);
      return {
        if (list is List)
          for (final id in list)
            if (id is String) id,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> _list(String uid, Set<String> ids) => ids.isEmpty
      ? _storage.delete(key: listKey(uid))
      : _write(listKey(uid), jsonEncode(ids.toList()..sort()));

  /// What is kept, or null when there is nothing that reads as settings.
  Future<ExportSettings?> read(String uid, String orchardId) async =>
      ExportSettings.fromText(await _read(storageKey(uid, orchardId)));

  /// Keeps [settings], and lists the Orchard first: an entry is never there
  /// without being listed.
  Future<void> write(String uid, String orchardId, ExportSettings settings) async {
    await _list(uid, {...await _orchards(uid, strict: true), orchardId});
    await _write(storageKey(uid, orchardId), settings.toText());
  }

  /// How far the device noted it got, as it wrote it; null when it noted
  /// nothing.
  Future<String?> readSent(String uid, String orchardId) => _read(sentKey(uid, orchardId));

  Future<void> writeSent(String uid, String orchardId, String text) => _write(sentKey(uid, orchardId), text);

  /// Forgets the key and the address, and how far it got: this device sends
  /// nothing more for that Orchard.
  Future<void> forget(String uid, String orchardId) async {
    await _storage.delete(key: storageKey(uid, orchardId));
    await _storage.delete(key: sentKey(uid, orchardId));
    await _list(uid, (await _orchards(uid, strict: true))..remove(orchardId));
  }
}
