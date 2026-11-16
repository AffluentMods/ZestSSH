#!/bin/bash
# ZestSSH's Linux release build, in the Ubuntu 20.04 root that focal_root.sh makes (3.2.2), Teams on,
# from a tag of this repo: the tarball goes to the Desktop, where build_linux_repo.sh makes the .deb,
# the .rpm and the repositories from it. Flutter is the WSL user's (~/flutter), lent to the root.
#
#   sudo bash tool/linux/build_linux_focal.sh <tag> <version> <build>
#
# Places, each from the environment when set, else found:
#   ZEST_REPO     the repository to build from: the one this script is in.
#   DESK_OUT      where the tarball goes: the Windows account's Desktop (OneDrive's when it keeps
#                 the Desktop), found through WSL's interop; set it for a trial run (DESK_OUT=/tmp).
#   FLUTTER_SRC   the Flutter SDK lent to the root: ~/flutter of the user who ran sudo, else of
#                 the WSL default user (uid 1000).
set -u
REF="$1"; VER="$2"; B="$3"
R=/opt/zest-focal
say() { echo "[$(date +%H:%M:%S)] $*"; }
[ "$(id -u)" = 0 ] || { say "FAILED: run as root"; exit 1; }
REPO=${ZEST_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { say "FAILED: $REPO is not a git checkout; set ZEST_REPO"; exit 1; }
WIN_PROFILE=$(/mnt/c/Windows/System32/cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
WIN_PROFILE=${WIN_PROFILE:+$(wslpath -u "$WIN_PROFILE" 2>/dev/null)}
if [ -z "${DESK_OUT:-}" ] && [ -n "$WIN_PROFILE" ]; then
  if [ -d "$WIN_PROFILE/OneDrive/Desktop" ]; then DESK_OUT="$WIN_PROFILE/OneDrive/Desktop"; else DESK_OUT="$WIN_PROFILE/Desktop"; fi
fi
DESK=${DESK_OUT:-}
[ -n "$DESK" ] && [ -d "$DESK" ] || { say "FAILED: no output folder; set DESK_OUT"; exit 1; }
BUILD_USER=${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}
BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
FLUTTER_SRC=${FLUTTER_SRC:-$BUILD_HOME/flutter}
[ -x "$FLUTTER_SRC/bin/flutter" ] || { say "FAILED: no Flutter SDK at $FLUTTER_SRC; set FLUTTER_SRC"; exit 1; }
[ -f "$R/usr/local/openssl3/lib64/libcrypto.a" ] || { say "FAILED: no build root; run focal_root.sh first"; exit 1; }
for d in proc sys dev dev/pts; do mountpoint -q "$R/$d" || mount --bind "/$d" "$R/$d"; done
mkdir -p "$R/opt/flutter"
mountpoint -q "$R/opt/flutter" || mount --bind "$FLUTTER_SRC" "$R/opt/flutter"
cp /etc/resolv.conf "$R/etc/resolv.conf"
rm -rf "$R/build/zestssh"; mkdir -p "$R/build"
git -c safe.directory='*' clone -q "$REPO" "$R/build/zestssh" || { say "FAILED: clone"; exit 1; }
git -C "$R/build/zestssh" checkout -q "$REF" || { say "FAILED: checkout $REF"; exit 1; }
cp "$REPO/.env" "$R/build/zestssh/.env"
# The release is built as ZestSSH, the release. Without this line in .env the build is a community
# build, with no sign-in, ZestSSH Cloud or updater (lib/config/official_identity.dart): it must not ship.
grep -Eq '^ZEST_OFFICIAL=true[[:space:]]*$' "$R/build/zestssh/.env" ||
  { say "FAILED: .env does not say ZEST_OFFICIAL=true: this would be a community build, not the release"; exit 1; }
say "at $(git -C "$R/build/zestssh" log --oneline -1 | cut -c1-60)"
chroot "$R" /bin/bash -c "
  export PATH=/opt/flutter/bin:\$PATH HOME=/root PUB_CACHE=/root/.pub-cache CI=true OPENSSL_ROOT_DIR=/usr/local/openssl3
  git config --global --add safe.directory '*'
  cd /build/zestssh
  flutter build linux --release --obfuscate --split-debug-info=build/debug-symbols-linux \
    --dart-define-from-file=.env --build-name=$VER --build-number=$B --dart-define=ZEST_ORCHARDS=true > /build/linux_focal.log 2>&1
"
BUNDLE="$R/build/zestssh/build/linux/x64/release/bundle"
if grep -q "Build process failed\|ERROR" "$R/build/linux_focal.log" || [ ! -x "$BUNDLE/zestssh" ]; then
  say "FAILED: linux; see $R/build/linux_focal.log"; tail -20 "$R/build/linux_focal.log"; exit 1
fi
# The proof on what was built: the release holds its API's address; a community build holds none.
grep -aq "api.zestssh.com" "$BUNDLE/lib/libapp.so" ||
  { say "FAILED: the built app does not hold the release's addresses: it is a community build"; exit 1; }
# Nothing in the bundle may name this machine: its users' folders, the checkout, the SDK.
leaks=(-e "StudioProjects" -e "updtest-" -e "$REPO" -e "$FLUTTER_SRC")
[ -n "$BUILD_HOME" ] && leaks+=(-e "$BUILD_HOME/")
[ -n "$WIN_PROFILE" ] && leaks+=(-e "Users/$(basename "$WIN_PROFILE")")
if grep -rlaF "${leaks[@]}" "$BUNDLE"; then
  say "FAILED: the bundle names this machine (files above)"; exit 1
fi
[ -f "$BUNDLE/install-desktop-entry.sh" ] || { say "FAILED: no install-desktop-entry.sh in the bundle"; exit 1; }
missing=$(chroot "$R" /bin/bash -c "cd /build/zestssh/build/linux/x64/release/bundle && LD_LIBRARY_PATH=lib ldd zestssh lib/*.so 2>&1 | grep 'not found' | sort -u")
[ -z "$missing" ] || { say "FAILED: libraries not found on 20.04: $missing"; exit 1; }
glibc=$(for f in "$BUNDLE/zestssh" "$BUNDLE"/lib/*.so; do objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*'; done | sort -u -V | tail -1)
objdump -p "$BUNDLE/lib/libsqlcipher_flutter_libs_plugin.so" | grep NEEDED | grep -qi 'crypto\|ssl' \
  && { say "FAILED: SQLCipher links the system's OpenSSL"; exit 1; }
name="ZestSSH-$VER-linux-x64.tar.gz"
tar czf "$DESK/$name" -C "$BUNDLE" .
say "linux: $name in $DESK, $(stat -c%s "$DESK/$name") bytes, sha256 $(sha256sum "$DESK/$name" | cut -c1-64), needs $glibc"
say DONE
