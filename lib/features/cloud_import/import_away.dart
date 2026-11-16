import 'dart:convert';
import 'dart:isolate';

// Reading a file chosen to import must never stop the screen, or the live
// sessions behind it: much of a file, or a file made to be slow, is looked at
// on another isolate. A file this small takes no time anywhere, and stays here.

/// How much is looked at on the screen's own thread.
const kImportHereBytes = 64 * 1024;

/// How many times a file was looked at or read on this isolate. Each isolate
/// has its own: this is a test's way to see that a large file went elsewhere.
int debugImportWorkHere = 0;

/// [work] on input of [bytes] bytes, on this thread where that is small. The
/// closure goes to another isolate, so it must hold only what it works on: make
/// it in a function of its own, never in a State.
Future<T> importWorkAway<T>(int bytes, T Function() work) async {
  if (bytes <= kImportHereBytes) return work();
  return Isolate.run(work);
}

/// [bytes] read as JSON, off the screen's thread where there is much to read.
Future<Object?> importJsonAway(List<int> bytes) => importWorkAway(bytes.length, () => jsonDecode(utf8.decode(bytes)));
