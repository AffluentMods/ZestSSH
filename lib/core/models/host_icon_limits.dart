import 'dart:convert';
import 'dart:typed_data';

/// The longest uploaded host picture that is kept, in base64: what the picker
/// makes is a 128-pixel PNG, well under this. A record or a backup that carries
/// more has its picture dropped, and the host stays.
const int kMaxHostIconChars = 96 * 1024;

/// The most pixels to a side of a host picture that is drawn. A small file can
/// say it is enormous, and it is decoded before it is shrunk to the tile.
const int kMaxHostIconSide = 1024;

/// The PNG in [b64], a host's uploaded picture, or null where there is none to
/// draw: too long, not base64, not a PNG (the picker makes only those), or a PNG
/// that says it is larger than [kMaxHostIconSide]. Others can write a team's
/// hosts, and a picture is decoded as soon as its card is on screen.
Uint8List? hostIconBytes(String? b64) {
  if (b64 == null || b64.isEmpty || b64.length > kMaxHostIconChars) return null;
  final Uint8List bytes;
  try {
    bytes = base64Decode(b64);
  } on FormatException {
    return null;
  }
  // The signature, then the first chunk: 4 bytes of length, "IHDR", width and
  // height as 4 bytes each.
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  final head = ByteData.sublistView(bytes, 16, 24);
  final width = head.getUint32(0);
  final height = head.getUint32(4);
  if (width == 0 || height == 0 || width > kMaxHostIconSide || height > kMaxHostIconSide) return null;
  return bytes;
}
