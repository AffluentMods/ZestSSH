/// Remote screens (4.0) for tests: a [FakeScreenNative] that plays the engine's side, so a
/// ScreenSession (and the app around it) runs without the Rust library.
library;

export 'src/screen_fake.dart' show FakeScreenNative, FakeScreenSession;
export 'src/screen_native.dart' show ScreenEventKind;
