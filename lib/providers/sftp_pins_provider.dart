import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/core/models/shared_pins.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The 3-level hidden-files setting. ONE value, applied to
/// both panes (the levels are defined per platform, not per pane), set in
/// Settings rather than a toolbar toggle.
enum SftpHiddenLevel {
  /// Hide only SYSTEM items - Windows System-attribute / protected-OS names /
  /// compat junctions locally, nothing on remote. The DEFAULT, so remote
  /// dotfiles (.ssh, .env, .bashrc) stay visible - they're the point of SFTP.
  systemOnly,

  /// The above PLUS dotfiles and Windows Hidden-attribute items (the old
  /// behaviour, kept for people who want it).
  hiddenAndSystem,

  /// Hide nothing.
  none,
}

const String _hiddenLevelKey = 'sftp_hidden_level';

final sftpHiddenLevelProvider =
    NotifierProvider<SftpHiddenLevelNotifier, SftpHiddenLevel>(
  SftpHiddenLevelNotifier.new,
);

class SftpHiddenLevelNotifier extends Notifier<SftpHiddenLevel> {
  @override
  SftpHiddenLevel build() {
    final v = ref.watch(sharedPreferencesProvider).getString(_hiddenLevelKey);
    return switch (v) {
      'hiddenAndSystem' => SftpHiddenLevel.hiddenAndSystem,
      'none' => SftpHiddenLevel.none,
      _ => SftpHiddenLevel.systemOnly,
    };
  }

  void setLevel(SftpHiddenLevel level) {
    state = level;
    ref
        .read(sharedPreferencesProvider)
        .setString(_hiddenLevelKey, level.name);
  }
}

/// How SFTP shows file times: 24-hour ("14:30", the default, as before the
/// setting existed) or 12-hour ("2:30 PM").
enum SftpTimeFormat {
  h24,
  h12;

  String get _clock => this == h12 ? 'h:mm a' : 'HH:mm';

  /// The app's language ([locale] for tests): AM and PM, and the short
  /// date's order, are the language's. Each was formatted without one, so
  /// every language read "2:30 PM" and the US date order (found in a
  /// code audit).
  static String _in(String? locale) => locale ?? gl10n.localeName;

  /// [make] in the language, or as before where its date names are not
  /// loaded (the app loads the language it is in).
  static DateFormat _format(DateFormat Function(String? locale) make, String? locale) {
    try {
      return make(_in(locale));
    } catch (_) {
      return make(null);
    }
  }

  /// "14:30" or "2:30 PM".
  String time(DateTime d, [String? locale]) => _format((l) => DateFormat(_clock, l), locale).formatPlain(d);

  /// "2026-09-24 14:30" or "2026-09-24 2:30 PM": the Modified column and the
  /// overwrite prompt.
  String dateTime(DateTime d, [String? locale]) => _format((l) => DateFormat('yyyy-MM-dd $_clock', l), locale).formatPlain(d);

  /// The locale's short date, then the time: the Properties sheet.
  String localeDateTime(DateTime d, [String? locale]) =>
      _format((l) => DateFormat.yMd(l).addPattern(_clock), locale).formatPlain(d);
}

const String _timeFormatKey = 'sftp_time_format';

/// The SFTP time format setting (device-local, like the other SFTP settings).
final sftpTimeFormatProvider =
    NotifierProvider<SftpTimeFormatNotifier, SftpTimeFormat>(
  SftpTimeFormatNotifier.new,
);

class SftpTimeFormatNotifier extends Notifier<SftpTimeFormat> {
  @override
  SftpTimeFormat build() =>
      ref.watch(sharedPreferencesProvider).getString(_timeFormatKey) ==
              SftpTimeFormat.h12.name
          ? SftpTimeFormat.h12
          : SftpTimeFormat.h24;

  void set(SftpTimeFormat format) {
    state = format;
    ref.read(sharedPreferencesProvider).setString(_timeFormatKey, format.name);
  }
}

const String _deleteHoldKey = 'sftp_delete_hold_seconds';

/// Allowed hold-window lengths for a REMOTE delete (delete safety spec §2.3):
/// 0 = off (unlink immediately, like an ordinary delete), else the seconds to
/// wait with Undo / Delete now before committing. Default 0 (off) - the delay
/// is opt-in; most users just delete normally.
const Set<int> kDeleteHoldChoices = {0, 5, 10, 30};

/// The `Delete hold` setting: seconds a remote delete waits before the unlink is
/// issued. Persisted; applies to remote deletes only (local uses the OS trash).
final sftpDeleteHoldSecondsProvider =
    NotifierProvider<SftpDeleteHoldSecondsNotifier, int>(
  SftpDeleteHoldSecondsNotifier.new,
);

class SftpDeleteHoldSecondsNotifier extends Notifier<int> {
  @override
  int build() {
    final v = ref.watch(sharedPreferencesProvider).getInt(_deleteHoldKey);
    return (v != null && kDeleteHoldChoices.contains(v)) ? v : 0;
  }

  void setSeconds(int seconds) {
    final v = kDeleteHoldChoices.contains(seconds) ? seconds : 0;
    state = v;
    ref.read(sharedPreferencesProvider).setInt(_deleteHoldKey, v);
  }
}

/// One SFTP rail pin: a label plus the path it points at.
/// The label is separate from the path so `Web root` can point at
/// `/var/www/html` and be renamed without moving.
class SftpPin {
  const SftpPin({required this.label, required this.path});

  final String label;
  final String path;

  Map<String, String> toJson() => {'label': label, 'path': path};

  static SftpPin? fromJson(dynamic j) {
    if (j is! Map) return null;
    final path = _cleanPinField(j['path']?.toString() ?? '');
    if (path.isEmpty) return null;
    final label = _cleanPinField(j['label']?.toString() ?? '');
    return SftpPin(label: label.isEmpty ? path : label, path: path);
  }

  SftpPin withLabel(String newLabel) =>
      SftpPin(label: newLabel.isEmpty ? path : newLabel, path: path);
}

/// Strip control (C0/C1) + bidi-override chars from a pin field at DECODE, so
/// the rail renders safely no matter how the column / prefs were populated. The
/// sync write-path (`_pinsJson`) also sanitizes; this is the render-layer
/// backstop, so a bug/bypass on the write side can't smuggle spoofing chars in.
/// The same cleaning as a team's shared bookmarks ([cleanPinText]).
String _cleanPinField(String s) => cleanPinText(s);

/// Parse the JSON pin list stored on a connection row (`Connections.pins`) or in
/// device prefs. Defensive - anything malformed yields an empty list; capped at
/// 100 pins (defense-in-depth; the sync write path caps too).
List<SftpPin> decodePins(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    final out = <SftpPin>[];
    for (final e in decoded) {
      if (out.length >= 100) break;
      final pin = SftpPin.fromJson(e);
      if (pin != null) out.add(pin);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Serialise a pin list for storage (the connection column or prefs).
String encodePins(List<SftpPin> pins) =>
    jsonEncode([for (final p in pins) p.toJson()]);

const String _localPinsKey = 'sftp_local_pins';

/// Device-local SFTP pins for "This PC". Local pins stay on the
/// device and never sync - a Windows path is meaningless on a phone and may not
/// exist on the user's other machine. Host pins live on the connection row
/// instead (`Connections.pins`) so they ride the existing connection sync.
final sftpLocalPinsProvider =
    NotifierProvider<SftpLocalPinsNotifier, List<SftpPin>>(
  SftpLocalPinsNotifier.new,
);

class SftpLocalPinsNotifier extends Notifier<List<SftpPin>> {
  @override
  List<SftpPin> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return decodePins(prefs.getString(_localPinsKey));
  }

  /// Whether local pins have EVER been written. Distinguishes
  /// "never used, show defaults" from "user cleared them, respect the empty
  /// list" - so a removed default stays removed and is never re-seeded.
  bool get isSeeded =>
      ref.read(sharedPreferencesProvider).containsKey(_localPinsKey);

  void _persist(List<SftpPin> next) {
    state = next;
    // Fire-and-forget: the in-memory state is authoritative for the UI; prefs
    // is the durable backing store.
    ref
        .read(sharedPreferencesProvider)
        .setString(_localPinsKey, encodePins(next));
  }

  /// Replace the whole list. The dual-pane screen builds the new pin list for
  /// every mutation (add / rename / move / remove) and routes it through here,
  /// keeping the local-pin and host-pin (`setPins` column) paths symmetric.
  void setAll(List<SftpPin> pins) => _persist(List.of(pins));
}
