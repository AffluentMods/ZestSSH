#!/bin/bash
# Build ZestSSH for Linux
# Run this on a Linux machine (Ubuntu 22.04+ recommended).
#
# Prerequisites (BUILDING.md has the details):
#   sudo apt update
#   sudo apt install -y clang cmake ninja-build pkg-config make g++ lld \
#     libgtk-3-dev liblzma-dev libstdc++-12-dev \
#     libsecret-1-dev libjsoncpp-dev libayatana-appindicator3-dev libssl-dev libasound2-dev
#
# libssl-dev must be OpenSSL 3 (Ubuntu 22.04 and later): the database links it.
# Flutter (the version in .fvmrc) must be on PATH, and rustup
# (https://rustup.rs) installed: the app's native library is written in Rust.
set -euo pipefail

echo "=== ZestSSH Linux Build ==="

# Check Flutter
if ! command -v flutter &> /dev/null; then
  echo "Error: Flutter not found. Install Flutter first."
  exit 1
fi

# Check rustup's cargo (the build hook also looks in ~/.cargo/bin)
if ! command -v cargo &> /dev/null && [ ! -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]; then
  echo "Error: cargo not found. Install rustup from https://rustup.rs first."
  exit 1
fi

# Check the libraries the plugins build against
missing=()
for lib in gtk+-3.0 liblzma libsecret-1 jsoncpp ayatana-appindicator3-0.1; do
  pkg-config --exists "$lib" || missing+=("$lib")
done
pkg-config --atleast-version=3.0 openssl || missing+=("openssl (3.0 or later)")
if [ ${#missing[@]} -gt 0 ]; then
  echo "Error: missing development packages: ${missing[*]} (see the apt line at the top of this script)"
  exit 1
fi

# Get dependencies
echo "Running flutter pub get..."
flutter pub get

# Build. Every release build is obfuscated, its debug symbols kept apart
# (never shipped), as the release runbook builds it; the app's settings come
# from .env where there is one.
echo "Building Linux release..."
ENV_ARGS=()
if [ -f .env ]; then ENV_ARGS=(--dart-define-from-file=.env); fi
# Which build this makes (lib/config/official_identity.dart): ZestSSH, the release, only with
# ZEST_OFFICIAL=true among the settings; otherwise a community build, which has no sign-in,
# ZestSSH Cloud or updater unless .env names services of its own (BUILDING.md).
if [ -f .env ] && grep -Eq "^ZEST_OFFICIAL=true[[:space:]]*$" .env; then
  echo "This is ZestSSH, the release (ZEST_OFFICIAL=true)."
else
  echo "This is a community build: no ZEST_OFFICIAL=true in .env."
fi
flutter build linux --release --obfuscate --split-debug-info=build/debug-symbols-linux ${ENV_ARGS[@]+"${ENV_ARGS[@]}"}

# Package
echo "Creating distributable archive..."
VERSION=$(grep 'version:' pubspec.yaml | head -1 | sed 's/version: //' | sed 's/+.*//')
BUNDLE_DIR="build/linux/x64/release/bundle"
OUTPUT="dist/ZestSSH-${VERSION}-linux-x64.tar.gz"

mkdir -p dist
cd "$BUNDLE_DIR"
tar czf "../../../../$OUTPUT" .
cd ../../../..

echo "=== Linux build complete! ==="
echo "Output: $OUTPUT"
echo ""
echo "Users install with:"
echo "  tar xzf ZestSSH-${VERSION}-linux-x64.tar.gz -C /opt/zestssh"
echo "  /opt/zestssh/zestssh"
