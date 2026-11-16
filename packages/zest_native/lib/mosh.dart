/// Mosh, built in (4.0): the Rust client of the Mobile Shell protocol (rust/src/mosh), behind
/// [MoshNative]. The app starts mosh-server over SSH and hands the port and key to [MoshNative.open].
library;

export 'src/mosh_native.dart' show MoshEventKind, MoshNative, MoshNativeEvent, RustMoshNative;
