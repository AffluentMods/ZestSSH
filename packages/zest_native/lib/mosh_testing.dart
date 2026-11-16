/// Mosh, built in (4.0), for tests: a [FakeMoshNative] that plays the client's side, so the app's
/// Mosh session runs without the Rust library.
library;

export 'src/mosh_fake.dart' show FakeMoshNative, FakeMoshSession;
export 'src/mosh_native.dart' show MoshEventKind;
