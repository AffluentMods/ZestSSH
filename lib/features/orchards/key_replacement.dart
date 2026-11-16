import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/utils/logger.dart';

/// How far the follow-up of a key replacement got on this device: the
/// account and key version it belongs to, and the steps done (`orchard:<id>`
/// and `crate:<id>` for new keys, `items:<orchardId>` for the items written
/// again). Kept so an interrupted run carries on where it stopped.
class KeyReplacementProgress {
  const KeyReplacementProgress({
    required this.uid,
    required this.version,
    this.done = const {},
  });

  final String uid;
  final int version;
  final Set<String> done;

  KeyReplacementProgress withDone(Set<String> done) =>
      KeyReplacementProgress(uid: uid, version: version, done: done);

  Map<String, dynamic> toJson() =>
      {'uid': uid, 'version': version, 'done': done.toList()..sort()};

  static KeyReplacementProgress? fromJson(Object? json) {
    if (json is! Map) return null;
    final uid = json['uid'];
    final version = json['version'];
    final done = json['done'];
    if (uid is! String || version is! int || done is! List) return null;
    return KeyReplacementProgress(
        uid: uid, version: version, done: done.whereType<String>().toSet());
  }
}

/// Where [KeyReplacementProgress] is kept.
abstract class KeyReplacementProgressStore {
  Future<KeyReplacementProgress?> read();
  Future<void> write(KeyReplacementProgress progress);
  Future<void> clear();
}

/// [KeyReplacementProgressStore] in the device's preferences: it names
/// Orchards and Crates by id and holds nothing secret.
class PrefsKeyReplacementProgressStore implements KeyReplacementProgressStore {
  PrefsKeyReplacementProgressStore(this._prefs);

  static const key = 'orchard_key_replacement_v1';
  final SharedPreferences _prefs;

  @override
  Future<KeyReplacementProgress?> read() async {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return KeyReplacementProgress.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(KeyReplacementProgress progress) =>
      _prefs.setString(key, jsonEncode(progress.toJson()));

  @override
  Future<void> clear() => _prefs.remove(key);
}

/// What a key replacement did.
class KeyReplacementReport {
  const KeyReplacementReport({
    required this.keyVersion,
    required this.copiesResealed,
    required this.left,
    this.stranded = 0,
  });

  /// The account's new key version.
  final int keyVersion;

  /// Orchard and Crate key copies sealed to the new keys.
  final int copiesResealed;

  /// Follow-up steps that could not be done yet; they are tried again after
  /// the next Orchard sync.
  final List<String> left;

  /// Items this account wrote last that sit in Crates where it can no
  /// longer edit: they could not be signed again with the new keys, so
  /// until someone who may edit them saves them, other devices refuse them.
  final int stranded;

  bool get complete => left.isEmpty;
}

/// The member.keys entries a key replacement brings for each Orchard's
/// record, as [AccountKeyService.replaceKeys] asks for them.
Future<Map<String, Map<String, dynamic>>> Function(
        String, AccountKeys, PublishedAccountKeys, Uint8List, Map<String, RecordHeadJson>)
    memberKeysRecords(OrchardService orchards) => (uid, next, published, endorsement, heads) async => {
          for (final e in (await orchards.memberKeysEntries(uid, next, published, endorsement, heads: {
            for (final h in heads.entries) h.key: RecordHead(h.value.seq, h.value.hash),
          }))
              .entries)
            e.key: e.value.toJson(),
        };

/// Replacing the account's keys after a device was lost or taken (3.0),
/// and everything that depended on the old keys:
///
/// 1. New account keys, published together with every Orchard and Crate key
///    copy the account holds, re-sealed to them, and a member.keys entry in
///    every Orchard's record, vouched for by the old keys (all or nothing on
///    the server; [AccountKeyService.replaceKeys]).
/// 2. New keys for every Orchard and Crate the account manages, so the old
///    account keys, and the Orchard and Crate keys a lost device already
///    opened, open nothing written from then on.
/// 3. Every item written again with the new keys, so nothing depends on the
///    old signing key and devices can refuse anything it signs.
///
/// Steps 2 and 3 are recorded as they finish, and [finish] carries them on
/// after an interruption (the Orchard sync calls it).
class KeyReplacement {
  KeyReplacement({
    required this.keys,
    required this.orchards,
    required this.sync,
    required this.progress,
    required this.forgetAuthor,
  });

  final AccountKeyService keys;
  final OrchardService orchards;
  final OrchardSyncCoordinator sync;
  final KeyReplacementProgressStore progress;

  /// Makes the Orchards ask for the account's keys again.
  final void Function() forgetAuthor;

  /// Runs the whole replacement. Throws what [AccountKeyService.replaceKeys]
  /// throws, before anything changed.
  Future<KeyReplacementReport> run() async {
    var copies = 0;
    final replaced = await keys.replaceKeys(
      reseal: (uid, next) async {
        final list = await orchards.resealAll(uid, next);
        copies = list.length;
        return list;
      },
      records: memberKeysRecords(orchards),
    );
    await progress.write(
        KeyReplacementProgress(uid: replaced.uid, version: replaced.keys.version));
    forgetAuthor();
    var stranded = 0;
    final left = await finish(onStranded: (n) => stranded += n);
    return KeyReplacementReport(
      keyVersion: replaced.keys.version,
      copiesResealed: copies,
      left: left,
      stranded: stranded,
    );
  }

  /// Carries on steps 2 and 3 of a replacement made on this device. Returns
  /// the steps still left; empty when all are done or there was nothing to
  /// do. Never throws for a step: a failed step is left for the next time.
  /// [onStranded] hears, per Orchard, how many of this account's items it
  /// could not sign again (see [KeyReplacementReport.stranded]).
  Future<List<String>> finish({void Function(int count)? onStranded}) async {
    final started = await progress.read();
    if (started == null) return const [];
    final me = await orchards.currentAuthor();
    if (me == null) return const ['keys'];
    if (me.uid != started.uid) return const []; // another account's
    if (me.keys.version > started.version) {
      // The keys were replaced again, on another device: its own follow-up
      // covers everything this one would have done.
      await progress.clear();
      return const [];
    }
    if (me.keys.version < started.version) return const ['keys']; // not here yet

    final done = {...started.done};
    Future<void> record(String step) async {
      done.add(step);
      await progress.write(started.withDone(done));
    }

    final left = <String>[];
    try {
      left.addAll(await orchards.rotateAll(skip: done, onMoved: record));
    } catch (e) {
      AppLogger.warning('Key replacement: new Orchard keys did not finish ($e)');
      return ['rotation'];
    }
    for (final orchardId in await orchards.databases.onDevice()) {
      final step = 'items:$orchardId';
      if (done.contains(step)) continue;
      try {
        final engine = await sync.engineFor(orchardId, author: me);
        final queued = await engine.queueRewrite();
        if (queued.stranded > 0) onStranded?.call(queued.stranded);
        final report = await sync.syncOne(orchardId, me: me);
        if (report.unsent == 0 &&
            report.tooLarge == 0 &&
            !report.needsKeys &&
            !report.staleAccountKeys) {
          await record(step);
        } else {
          left.add(step);
        }
      } catch (e) {
        AppLogger.warning('Key replacement: items did not all go again ($e)');
        left.add(step);
      }
    }
    if (left.isEmpty) await progress.clear();
    return left;
  }
}
