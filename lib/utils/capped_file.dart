import 'dart:io';
import 'dart:typed_data';

/// The file at [path] whole, or null where it is longer than [maxBytes]: no more
/// than that and one byte is ever read, whatever its size said a moment before.
/// For a file a person chooses to import: it can be anything, of any size.
Future<Uint8List?> readFileCapped(String path, int maxBytes) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File(path).openRead(0, maxBytes + 1)) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) return null;
  }
  return bytes.takeBytes();
}
