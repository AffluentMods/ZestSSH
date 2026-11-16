# Building ZestSSH from source

This page takes a clean machine to a running debug build of ZestSSH, on each platform. Everything the build needs is
in this repository or is downloaded by the build itself; no file of ours that is not in the repository is needed for
a debug build on Windows, macOS or Linux.

## 1. What every platform needs

| Tool | Version | Where it is fixed |
|---|---|---|
| Flutter (stable) | 3.50.0 | `.fvmrc` (read by [FVM](https://fvm.app); without FVM, install that version and check `flutter --version`), `pubspec.yaml` (`environment: flutter`) |
| Dart | comes with Flutter | `pubspec.yaml` |
| Rust, through rustup | 1.99.1, installed by rustup on the first build with every target the app ships (about 1.9 GB, needs the network once) | `packages/zest_native/rust/rust-toolchain.toml` |
| git | any recent | |
| A C and C++ toolchain | per platform, below | the Rust crate `ring` and the plugins compile C and C++ |

There is no private package registry, no git dependency and no submodule. The path dependencies
(`packages/zest_native`, `packages/zest_ssh_core`, `packages/xterm`, `packages/desktop_multi_window`,
`packages/speech_to_text_windows`, the last through `dependency_overrides`) are in this
repository. The Rust crates come from crates.io, locked by `packages/zest_native/rust/Cargo.lock`.

### Rust

Install rustup from https://rustup.rs. The minimal profile is enough:

- Windows: run `rustup-init.exe`, choose a custom install with profile `minimal` and no default toolchain.
- macOS and Linux:
  `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none`

Every `flutter run`, `flutter build` and `flutter test` builds the Rust library first, through the build hook
`packages/zest_native/hook/build.dart` (`cargo build --release --locked` for the platform's target). It looks for
`cargo` on `PATH`, then in `$CARGO_HOME/bin`, then in `~/.cargo/bin`. Without rustup, every build and every test run
stops at "Running build hooks" with "cargo was not found".

The library is built for these targets only; any other (Windows on ARM, Linux on ARM) stops with "zest_native is not
built for ...":

| Platform | Rust targets |
|---|---|
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` |
| iOS | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` |
| Windows | `x86_64-pc-windows-msvc` |
| Linux | `x86_64-unknown-linux-gnu` |

### First steps after cloning

```
git clone <this repository> zestssh
cd zestssh
flutter pub get
flutter gen-l10n
```

- `lib/l10n/generated/` is not in git. If it is missing or stale the app does not compile ("Target of URI doesn't
  exist: package:zestssh/l10n/generated/app_localizations.dart"). Run `flutter gen-l10n` after every pull and every
  change to `lib/l10n/*.arb`.
- The database code (`lib/database/**/*.g.dart`) is in git. Run `dart run build_runner build` only after changing a
  table or a DAO.

### Build settings

No settings file is needed: every setting has a default, and none stops a build or a start. The settings are
compile-time defines; [`.env.example`](.env.example) lists every one the app reads, with what it does and its
default. To set some, copy it to `.env` (ignored by git), remove the `# ` in front of the lines you want, and pass
`--dart-define-from-file=.env`; or pass single `--dart-define=NAME=value` arguments.

- **Never put a secret in them**: each value is compiled into the app as readable text.
- **Without settings, a build is a community build** (`ZEST_OFFICIAL` unset). It starts and connects as always:
  hosts, keys, SFTP, port forwards, remote screens, automation, backups and sync to your own storage all work. It has
  no accounts, ZestSSH Cloud, teams, plans, tickets, updater or Store hand-over, and no links to a website, docs,
  community chat, policy or support, unless you name your own with the settings below. About says "Community build"
  (or your `ZEST_BUILD_NAME`), and a copied report says the same. Limits on paid features stay as they are; the
  upgrade page says there are no plans to buy in this build. For now its data folders, application id and link
  scheme are still the official app's, so do not run it beside an installed ZestSSH with real data.
- Only the official builds set `ZEST_OFFICIAL=true`; their addresses (account, ZestSSH Cloud, Teams, the docs,
  support, the community chat, the store listings) are kept in `lib/config/official_identity.dart`. A community build
  pointed at a service of its own sends `X-ZestSSH-Build: community` with its requests.
- Setting `WEBSITE_URL` moves every website page to that site: privacy, terms, download, account security, browser
  sign-in, the upgrade checkout, the plans page and the passkey origin's default. A team's join links have their own
  setting, `ZEST_JOIN_LINK_BASE`, because the links a phone opens in the app are the ones registered when it was
  installed.
- The in-app updater reads its manifest from `ZEST_UPDATE_HOST` and accepts it only when it is signed with
  `ZEST_UPDATE_KEY` or `ZEST_UPDATE_KEY_2`. By default those are the official site and the release's key, so a build
  you give to others names its own, or sets `ZEST_UPDATE_KEY` empty: a build with no key takes no update.
  `ZEST_APP_STORE_ID` and `ZEST_PLAY_PACKAGE` name the store listings the review links open (empty: none), and
  `ZEST_MAKER_URL` the maker's site; each defaults to the release's value.
- `ZEST_BUILD_NAME` names your build (About and reports); the official builds leave it empty.
- The tests are run with `--dart-define=ZEST_ORCHARDS=true` (Teams compiled in).

The build itself reads `PATH`, `CARGO_HOME`, `RUSTUP_HOME`, `HOME` or `USERPROFILE`, and on a Mac `SDKROOT`. Nothing
reads a `.env` file at run time.

## 2. Windows (x64)

- Windows 10 or 11, x64.
- Visual Studio 2022 or newer with the workload "Desktop development with C++" (MSVC, the Windows SDK, CMake).
- **OpenSSL 3.0 or later for MSVC x64, with its static libraries.** The database plugin (`sqlcipher_flutter_libs`)
  links OpenSSL's libcrypto into the app and stops at the CMake step without it. Install the full (not "Light")
  Win64 OpenSSL 3 installer from https://slproweb.com/products/Win32OpenSSL.html at its default place
  (`C:\Program Files\OpenSSL-Win64`), or build it with vcpkg (`vcpkg install openssl:x64-windows-static`) and set
  `OPENSSL_ROOT_DIR` to its folder. OpenSSL 1.1.1 and older are refused by `windows/CMakeLists.txt`: their licence
  does not fit this project's, and SQLCipher asks for 3.
- rustup (section 1).
- The network at build time: plugins download PDFium and the Firebase C++ SDK on the first build.

```
flutter run -d windows
flutter build windows --release
```

The program is in `build\windows\x64\runner\Release\`; copy the whole folder. Build from a short path: paths under
`build\` can pass 260 characters. The installer of the official releases is made with Inno Setup 6 from
`installer\zestssh_setup.iss`.

## 3. Linux (x86_64)

Prerequisites (Debian and Ubuntu names; Ubuntu 22.04 or later, for OpenSSL 3):

```
sudo apt install -y clang cmake ninja-build pkg-config make g++ lld \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libsecret-1-dev libjsoncpp-dev libayatana-appindicator3-dev libssl-dev libasound2-dev \
  git curl unzip xz-utils zip
```

`libssl-dev` must be OpenSSL 3.0 or later (`linux/CMakeLists.txt` refuses an older one; set `OPENSSL_ROOT_DIR` to an
OpenSSL 3 of your own on an older system). At run time the app needs a Secret Service (GNOME Keyring or KWallet) for
its keychain, and ALSA (`libasound2`) for a remote desktop's sound. rustup as in section 1.

```
flutter run -d linux
flutter build linux --release
```

`scripts/build_linux.sh` checks these prerequisites, builds a release and packs it as a tarball. The bundle is
`build/linux/x64/release/bundle/`. A build made on your system runs on systems at least as new as yours.

## 4. macOS

Prerequisites: macOS with Xcode and its command line tools (`xcode-select --install`), CocoaPods, rustup. Deployment
target macOS 11.0.

```
flutter run -d macos
flutter build macos --release
```

The project signs ad hoc, so no Apple account is needed. The app is in `build/macos/Build/Products/Release/`.

## 5. Android

- Android Studio or the command line tools, with the SDK platform Flutter asks for, the build tools, and the NDK
  version Flutter names (`flutter.ndkVersion`).
- JDK 17. Gradle and the Android Gradle Plugin are downloaded by the build. The Gradle daemon is given 8 GB
  (`android/gradle.properties`); lower `-Xmx8G` on a small machine.
- minSdk 26 (Android 8.0). rustup as in section 1.
- No Firebase file is needed. Without `android/app/google-services.json` (not in the repository) the app builds and
  runs without Firebase, which only signing in on the device uses. With one of your own (from a Firebase project, for
  the app's application id) the Google services Gradle plugin is applied. A build made with `ZEST_OFFICIAL=true`
  stops when the file is missing.

```
flutter run -d <device or emulator>
flutter build apk --release
```

A release build needs a signing key of your own: create `android/key.properties` (ignored by git) with `storeFile`,
`storePassword`, `keyAlias` and `keyPassword`. Without it a release build stops at signing on purpose.

## 6. iOS

Prerequisites: a Mac with Xcode, CocoaPods and rustup, and an Apple developer team of your own. Deployment target
iOS 15.0. In Xcode, target Runner, Signing and Capabilities: choose your team and set your own bundle identifier.
The project expects `ios/Runner/GoogleService-Info.plist` (not in the repository) from a Firebase project of your
own.

```
flutter run -d <simulator or device>
flutter build ios --release
```

## 7. Tests

```
flutter test --no-pub --dart-define=ZEST_ORCHARDS=true
```

- `--no-pub` skips `flutter pub get`. Run `flutter pub get` and `flutter gen-l10n` once before.
- The Rust library is built first, so the first run takes minutes.
- One file: `flutter test --no-pub --dart-define=ZEST_ORCHARDS=true test/<path>_test.dart`.
- The SSH library: `dart test -x integration` inside `packages/zest_ssh_core`.
- The native library: `cargo test --features vnc` inside `packages/zest_native/rust`.
- `flutter analyze` must show no new issue.
- Never run `dart format` on a directory: format only the files you create.
- Licences: `dart run tool/licence_check.dart` checks every Dart package and Rust crate the app ships against the
  licences this project accepts (section 9).

Tests that need something this repository does not run for you skip themselves:

| Tests | Need |
|---|---|
| `*_real_host_test.dart`, `*_real_shell_test.dart`, certificate sign-in tests | the local SSH servers of `tool/test_sshd.sh` (Linux, or WSL on Windows) |
| `test/native/ftps_integration_test.dart` | the local FTPS server of `tool/test_ftps_server.sh` |
| remote screen tests against servers | the servers of `tool/remote_screens_test_servers.sh` |
| `*_contract_test.dart` | the ZestSSH Cloud server's own test stand-in, which is not in this repository |
| tests tagged `real-tmux` | tmux (native, or in WSL on Windows) |

## 8. Known gotchas

- **`flutter pub get` rewrites the plugin registrant files** (`linux/flutter/`, `macos/Flutter/`, `windows/flutter/`),
  which are in git: they show as changed. Do not commit them;
  `git checkout -- linux/flutter macos/Flutter windows/flutter` puts them back.
- **Run `flutter gen-l10n` after switching branches or pulling.** `flutter test --no-pub` does not regenerate it.
- **"cargo was not found"**: install rustup (section 1).
- **The first build downloads** the Rust toolchain and targets, the crates, Gradle and Maven artefacts, CocoaPods,
  and on Windows PDFium and the Firebase C++ SDK.
- **A debug build keeps its database unencrypted.** Never put real hosts or keys in a debug build.

## 9. Licences of what the app includes

ZestSSH itself is under the GNU General Public License version 3 only, with an additional permission under its
section 7 (`LICENSE`, `LICENSE-EXCEPTION.txt`, `NOTICE`), which the app shows with the others (`third_party/zestssh/`).
The app shows every licence it carries under About, Open source licenses: the Dart packages' own, the Rust crates'
(`packages/zest_native/NOTICES`, written by `tool/rust_notices.dart`), the bundled fonts' and the code copied into
this repository (`third_party/`, listed under `flutter: licenses:` in `pubspec.yaml`), and the native libraries of
the platform the app runs on (`assets/licenses/`). `tool/licence_check.dart` fails when a Dart package or Rust crate
comes under a licence that is not on its list (`tool/licence_policy.yaml`).

## 10. Official release builds

The releases published by Affluent Labs LLC are built with `--obfuscate --split-debug-info=<folder>` and their settings
file; the debug symbols are kept off this repository, so that crash reports from a release can still be read. A build
of your own needs neither.
