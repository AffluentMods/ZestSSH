/// ZestSSH's native library, written in Rust (3.4). Built for each platform by hook/build.dart
/// and loaded by Dart's native assets; see BUILDING.md at the top of the repository.
library;

import 'package:ffi/ffi.dart';

import 'src/bindings.dart';

/// The native library's name and version, for example "zest_native 0.1.0". Calling it loads the
/// library: it throws where the library is not part of this build.
String zestNativeVersion() => zestNativeVersionC().toDartString();
