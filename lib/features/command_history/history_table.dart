/// What a computer's History page shows of the recorded commands (3.0): the
/// rows grouped by day, repeats run one after another counted on one row,
/// the commands that say little (cd, ls, clear...) marked so a day can hide
/// them, a folder under the home folder written from `~`, and a run time
/// written short. Pure (but for the host a link asks for), so it is tested
/// without a screen. It reads what was recorded and changes nothing of it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';

/// The commands that say little about what was done, by their first word:
/// moving around and looking (cd, ls, pwd), clearing the screen, leaving.
/// Kept short on purpose: a command only counts when it is one of these on
/// its own (no pipe, no `;`, no `&&`, no redirection), so `ls | grep x` or
/// `cd /srv && make` always shows.
const Set<String> trivialCommandWords = {
  'cd',
  'ls',
  'll',
  'la',
  'l',
  'pwd',
  'clear',
  'cls',
  'reset',
  'exit',
  'logout',
  'history',
  'whoami',
};

/// What joins or redirects commands: a line with any of these does more
/// than one trivial thing, so it is never trivial.
final RegExp _compound = RegExp(r'[|;&<>`]|\$\(');

/// Whether [command] is a trivial one (see [trivialCommandWords]).
bool isTrivialCommand(String command) {
  final line = command.trim();
  if (line.isEmpty || line.contains('\n') || _compound.hasMatch(line)) return false;
  final first = line.split(RegExp(r'\s+')).first;
  return trivialCommandWords.contains(first);
}

/// [cwd] with the home folder of [user] written `~` (`/home/ana/site` is
/// `~/site`; root's home is `/root`, a Mac's `/Users/ana`). As it is where
/// the user is not known or the folder is not under that home.
String shortenHomeFolder(String cwd, String? user) {
  if (user == null || user.isEmpty) return cwd;
  final homes = user == 'root' ? const ['/root'] : ['/home/$user', '/Users/$user'];
  for (final home in homes) {
    if (cwd == home || cwd == '$home/') return '~';
    if (cwd.startsWith('$home/')) return '~${cwd.substring(home.length)}';
  }
  return cwd;
}

/// How long a command ran, as short as it can be said: under ten seconds to
/// a tenth (`0.1s`, `1.8s`; under a tenth is `<0.1s`), under a minute in
/// seconds (`41s`), under an hour in minutes (`18m`), then hours and
/// minutes (`2h 5m`). The units come from [seconds], [minutes] and [hours]
/// (the page's language), the decimal mark from [decimalSeparator].
String formatTook(
  int ms, {
  required String Function(String seconds) seconds,
  required String Function(int minutes) minutes,
  required String Function(int hours, int minutes) hours,
  required String decimalSeparator,
}) {
  if (ms < 100) return '<${seconds('0${decimalSeparator}1')}';
  if (ms < 10000) {
    final tenths = (ms / 100).round();
    if (tenths >= 100) return seconds('10');
    return seconds('${tenths ~/ 10}$decimalSeparator${tenths % 10}');
  }
  if (ms < 60000) return seconds('${(ms / 1000).round().clamp(10, 59)}');
  if (ms < 3600000) return minutes((ms / 60000).floor());
  final h = ms ~/ 3600000;
  return hours(h, (ms % 3600000) ~/ 60000);
}

/// The host a row ran on, as the page tells hosts apart: its saved host
/// where it has one, else the name it was recorded under.
/// The host the History page should show next ([historyHostKey]), asked for
/// by a link that opens it for one host (the Inspector's History, by its
/// session's host). The page takes it and puts it back to null.
final historyHostWantedProvider = StateProvider<String?>((ref) => null);

String? historyHostKey(CommandHistoryEntry e) {
  final id = e.connectionId;
  if (id != null && id.isNotEmpty) return 'id:$id';
  final label = e.hostLabel;
  if (label != null && label.isNotEmpty) return 'label:$label';
  return null;
}

/// One row of the table: [entry] (the newest of the run) and how many times
/// in a row it ran on that host.
class HistoryRun {
  const HistoryRun(this.entry, this.repeat);

  final CommandHistoryEntry entry;
  final int repeat;

  bool get trivial => isTrivialCommand(entry.command);
}

/// One day of the table: its [day] (midnight, local) and its rows, newest
/// first.
class HistoryDay {
  const HistoryDay(this.day, this.runs);

  final DateTime day;
  final List<HistoryRun> runs;

  /// The commands of the day, each repeat counted.
  int get count => runs.fold(0, (n, r) => n + r.repeat);

  /// The day's trivial rows.
  List<HistoryRun> get trivialRuns => [for (final r in runs) if (r.trivial) r];
}

/// [newestFirst] grouped by local day, newest day first; within a day, the
/// same command run again right after itself on the same host is one row
/// with its count.
List<HistoryDay> groupHistoryByDay(List<CommandHistoryEntry> newestFirst) {
  final days = <HistoryDay>[];
  DateTime? day;
  var runs = <HistoryRun>[];
  for (var i = 0; i < newestFirst.length;) {
    final e = newestFirst[i];
    final d = DateTime(e.createdAt.year, e.createdAt.month, e.createdAt.day);
    if (d != day) {
      if (day != null) days.add(HistoryDay(day, runs));
      day = d;
      runs = <HistoryRun>[];
    }
    var count = 1;
    while (i + count < newestFirst.length) {
      final next = newestFirst[i + count];
      final nd = DateTime(next.createdAt.year, next.createdAt.month, next.createdAt.day);
      if (next.command != e.command || historyHostKey(next) != historyHostKey(e) || nd != d) break;
      count++;
    }
    runs.add(HistoryRun(e, count));
    i += count;
  }
  if (day != null) days.add(HistoryDay(day, runs));
  return days;
}
