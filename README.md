# ZestSSH

ZestSSH is an SSH client for Android, iOS, Windows, macOS and Linux: hosts, terminal, files, keys, tunnels and remote
screens in one app, with end-to-end encrypted sync.

It is built with Flutter, with its SSH engine in Dart (`packages/zest_ssh_core`) and its native parts (FTPS, the
remote screen engine) in Rust (`packages/zest_native`).

## What it does

- **SSH and terminal**: Ed25519, Ed448, ECDSA and RSA keys, OpenSSH certificates, hardware keys through the system's
  agent, agent forwarding, jump hosts, port forwarding, Mosh and Eternal Terminal, tmux sessions, split panes.
- **Files**: SFTP with two panes, FTPS, a text editor, folder sync.
- **Remote screens**: VNC and RDP, in the app's own engine (a fork of vnc-rs, and IronRDP).
- **Local data**: an SQLCipher database (Drift), its key in the system's keystore.
- **Sync**: end-to-end encrypted (Argon2id and AES-256-GCM); free through your own storage (WebDAV, S3-compatible
  storage, Google Drive), or hosted by ZestSSH Cloud.
- **Teams**: shared vaults, roles, team certificates and session sharing, with a ZestSSH Cloud account.

## Platforms

| Platform | Build host | Notes |
|---|---|---|
| Windows 10 and 11, x64 | Windows | Visual Studio C++ tools and OpenSSL 3 |
| Linux, x86_64 | Linux | GTK 3, libsecret, OpenSSL 3 |
| macOS 11 or later | macOS | Xcode, CocoaPods |
| Android 8.0 or later | any | Android SDK and NDK, JDK 17 |
| iOS 15 or later | macOS | Xcode, CocoaPods, an Apple developer team |

## Building

```
flutter pub get
flutter gen-l10n
flutter run
```

Flutter 3.50.0 (`.fvmrc`) and rustup are needed on every platform. [BUILDING.md](BUILDING.md) has the steps for
each platform, the build settings ([`.env.example`](.env.example)), the tests and the known gotchas.

Official release builds are compiled with `--obfuscate --split-debug-info`, and their debug symbols are kept off
this repository so that crash reports can be read back; a build of your own needs neither.

## Repository layout

```
lib/                  the app (Riverpod, GoRouter; screens in lib/ui and lib/features)
packages/
  zest_ssh_core/      the SSH library, a fork of dartssh2 (MIT)
  zest_native/        the Rust library: FTPS and the remote screen engine
  xterm/              the terminal renderer, a fork of xterm.dart (MIT)
  desktop_multi_window/  detached windows, a fork (Apache-2.0)
  speech_to_text_windows/  speech to text on Windows, a fork (BSD-3-Clause)
  lucide_icons/       the Lucide icons for Flutter, a fork (ISC)
test/                 the tests (flutter test)
tool/                 developer tools: test servers, licence notices and checks
third_party/          the licences the app shows: its own, and those of its fonts and copied code
docs/                 design notes, the error codes and the self-hosted sync guide
```

[architecture.md](architecture.md) maps the code in more detail.

## Licence

ZestSSH is free software, licensed under the GNU General Public License version 3 only ([LICENSE](LICENSE)), with an
additional permission under its section 7 ([LICENSE-EXCEPTION.txt](LICENSE-EXCEPTION.txt)) that lets the app be
linked with the closed libraries its official builds use: on Android, Google Play services, ML Kit, Firebase, the
Google Play libraries and the Amazon Appstore SDK, and the others that file lists. SPDX: `GPL-3.0-only`, with that
permission. Versions released before 4.0 were not published under this licence.

© 2026 Affluent Labs LLC. All rights reserved.

The packages under `packages/` that carry a LICENSE file of their own keep it (zest_ssh_core and xterm are MIT), as
do the vendored code and crates in `packages/zest_native/rust` and the fonts and code in `third_party/`. The app
lists every third-party licence it carries under About, Open source licenses. [NOTICE](NOTICE) sums it up.

"ZestSSH" and its logo are trademarks of Affluent Labs LLC and are not licensed under the GPL: see
[TRADEMARKS.md](TRADEMARKS.md). Contributions are welcome under the contributor licence agreement in
[CLA.md](CLA.md): see [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please do not report a security problem in a public issue. The disclosure policy and its contact are at
https://zestssh.com/security-disclosure, and in [SECURITY.md](SECURITY.md).

## Documentation

The user guides are at https://docs.zestssh.com.
