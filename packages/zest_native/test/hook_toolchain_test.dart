// The build hook holds the build to the pinned Rust toolchain (found in a review before 4.0): the
// caller's environment cannot move it to another toolchain, compiler, wrapper or flags, and a
// cargo that is not rustup's (so ignores rust/rust-toolchain.toml) stops the build with words that
// say what to do.
import 'dart:io';

import 'package:test/test.dart';

import '../hook/build.dart' as hook;

void main() {
  group('what cargo is run with', () {
    test('leaves out what would move the build, sets the wrappers to none, and keeps the rest', () {
      final env = hook.cargoEnvironment(
        {
          'PATH': '/usr/bin',
          'HOME': '/home/alex',
          'CARGO_HOME': '/opt/cargo',
          'RUSTUP_HOME': '/opt/rustup',
          'HTTPS_PROXY': 'http://proxy.example:3128',
          'CARGO_NET_OFFLINE': 'true',
          'CARGO_REGISTRIES_CRATES_IO_PROTOCOL': 'sparse',
          'CC': 'clang',
          'RUSTUP_TOOLCHAIN': 'nightly',
          'RUSTC': '/tmp/rustc',
          'RUSTC_WRAPPER': '/tmp/wrap',
          'RUSTC_WORKSPACE_WRAPPER': '/tmp/wrap2',
          'RUSTDOC': '/tmp/rustdoc',
          'RUSTFLAGS': '-C debug-assertions',
          'RUSTDOCFLAGS': '-Z x',
          'CARGO_ENCODED_RUSTFLAGS': '--cfg=theirs',
          'RUSTC_BOOTSTRAP': '1',
          'CARGO_TARGET_DIR': '/tmp/out',
          'CARGO_BUILD_RUSTC': '/tmp/rustc',
          'CARGO_BUILD_RUSTFLAGS': '-C opt-level=0',
          'CARGO_PROFILE_RELEASE_DEBUG': 'true',
          'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER': '/tmp/ld',
          'CARGO_UNSTABLE_BUILD_STD': 'true',
          'rustup_toolchain': 'beta',
        },
        {'CARGO_ENCODED_RUSTFLAGS': '--remap-path-prefix=/home/alex=/home', 'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER': 'ndk-clang'},
      );
      expect(env, {
        'PATH': '/usr/bin',
        'HOME': '/home/alex',
        'CARGO_HOME': '/opt/cargo',
        'RUSTUP_HOME': '/opt/rustup',
        'HTTPS_PROXY': 'http://proxy.example:3128',
        'CARGO_NET_OFFLINE': 'true',
        'CARGO_REGISTRIES_CRATES_IO_PROTOCOL': 'sparse',
        'CC': 'clang',
        'RUSTC_WRAPPER': '',
        'RUSTC_WORKSPACE_WRAPPER': '',
        // The build's own, after: the flags that keep the builder's folders out, the NDK's linker.
        'CARGO_ENCODED_RUSTFLAGS': '--remap-path-prefix=/home/alex=/home',
        'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER': 'ndk-clang',
      });
    });
  });

  group('the cargo that was found', () {
    String? problem(String channel, String output) =>
        hook.pinnedToolchainProblem(channel: channel, versionOutput: output, cargo: '/usr/bin/cargo');

    test("rustup's, running the pinned toolchain: nothing is wrong", () {
      expect(problem('1.99.1', 'cargo 1.99.1 (abcdef012 2026-09-01)\n'), isNull);
      expect(problem('1.99', 'cargo 1.99.4 (abcdef012 2026-10-01)'), isNull, reason: 'a pin without a patch takes any');
    });

    test('another version (a system package\'s cargo, which ignores the pin): the build stops and says what to do', () {
      final said = problem('1.99.1', 'cargo 1.75.0 (1d8b05cdd 2023-11-20)');
      expect(said, contains('/usr/bin/cargo'));
      expect(said, contains('version 1.75.0'));
      expect(said, contains('1.99.1'));
      expect(said, contains('https://rustup.rs'));
      expect(said, contains('BUILDING.md'));
      expect(problem('1.99', 'cargo 1.990.0 (x 2030-01-01)'), isNotNull, reason: '1.990 is not 1.99');
    });

    test('nothing readable came back: the build stops', () {
      expect(problem('1.99.1', ''), contains('not one this build can read the version of'));
      expect(problem('1.99.1', 'error: toolchain is not installed'), isNotNull);
    });

    test('a pin by name holds the build to no version', () {
      expect(problem('stable', 'cargo 1.75.0 (1d8b05cdd 2023-11-20)'), isNull);
    });

    test('the pin of this repository is a version, so it is held', () {
      final toml = File('rust/rust-toolchain.toml').readAsStringSync();
      final channel = RegExp(r'^\s*channel\s*=\s*"([^"]+)"', multiLine: true).firstMatch(toml)!.group(1)!;
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(channel), isTrue, reason: channel);
      expect(problem(channel, 'cargo $channel (abcdef012 2026-09-01)'), isNull);
    });
  });
}
