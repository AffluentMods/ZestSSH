#!/bin/bash
# The Ubuntu 20.04 build root for ZestSSH's Linux release (3.2.2): built there, the app asks for glibc
# 2.29 at most, so the packages run on Ubuntu 20.04 and later, Debian 11 and later, and RHEL and Rocky 9
# (built on Ubuntu 26.04 it asked for 2.38, and left those out). Run once as root in WSL; it does
# nothing it has already done.
#
#   sudo bash tool/linux/focal_root.sh
#
# 1. A 20.04 root at /opt/zest-focal (debootstrap), with the compilers and the -dev packages the app's
#    plugins build against, and lld (Flutter's native build hooks link with it).
# 2. OpenSSL 3.5 (the long-term branch), static and position-independent, at /usr/local/openssl3 in
#    the root, for SQLCipher to link into the app: 20.04's own OpenSSL is 1.1, which SQLCipher cannot
#    use, and linked in, the app needs no OpenSSL from the system at all. Its tarball is checked
#    against the SHA-256 that is published beside it.
set -eu
R=/opt/zest-focal
say() { echo "[$(date +%H:%M:%S)] $*"; }
[ "$(id -u)" = 0 ] || { say "FAILED: run as root"; exit 1; }

if [ ! -x "$R/usr/bin/apt-get" ]; then
  apt-get -qq update && apt-get -qq install -y debootstrap > /dev/null
  say "debootstrap focal"
  debootstrap --variant=minbase --components=main,universe focal "$R" http://archive.ubuntu.com/ubuntu > /tmp/focal_debootstrap.log 2>&1 \
    || { say "FAILED: debootstrap, see /tmp/focal_debootstrap.log"; exit 1; }
fi
cat > "$R/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu focal main universe
deb http://archive.ubuntu.com/ubuntu focal-updates main universe
deb http://security.ubuntu.com/ubuntu focal-security main universe
EOF
cp /etc/resolv.conf "$R/etc/resolv.conf"
for d in proc sys dev dev/pts; do mountpoint -q "$R/$d" || mount --bind "/$d" "$R/$d"; done
say "packages"
chroot "$R" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && apt-get -qq install -y --no-install-recommends \
  ca-certificates git curl unzip xz-utils zip file binutils clang lld-10 llvm-10 cmake ninja-build pkg-config make g++ \
  libgtk-3-dev libsecret-1-dev libasound2-dev libjsoncpp-dev libayatana-appindicator3-dev liblzma-dev tcl libstdc++-10-dev > /tmp/apt.log 2>&1 \
  || { tail -20 /tmp/apt.log; exit 1; }'

if ! [ -f "$R/usr/local/openssl3/lib64/libcrypto.a" ]; then
  V=$(curl -fsSL 'https://api.github.com/repos/openssl/openssl/releases?per_page=60' | grep -o '"tag_name": "openssl-3\.5\.[0-9]*"' | grep -o '3\.5\.[0-9]*' | sort -V | tail -1)
  [ -n "$V" ] || { say "FAILED: no OpenSSL 3.5 release found"; exit 1; }
  T=$R/build/openssl; rm -rf "$T"; mkdir -p "$T"; cd "$T"
  curl -fsSLO "https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz"
  curl -fsSLO "https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz.sha256"
  want=$(grep -o '[0-9a-f]\{64\}' "openssl-$V.tar.gz.sha256" | head -1)
  got=$(sha256sum "openssl-$V.tar.gz" | cut -c1-64)
  [ "$want" = "$got" ] || { say "FAILED: OpenSSL $V sha256 $got, published $want"; exit 1; }
  tar xzf "openssl-$V.tar.gz"
  say "OpenSSL $V (sha256 $got)"
  chroot "$R" /bin/bash -c "cd /build/openssl/openssl-$V && ./Configure linux-x86_64 no-shared no-tests no-docs -fPIC \
    --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3/ssl > /build/openssl/configure.log 2>&1 \
    && make -j\$(nproc) > /build/openssl/make.log 2>&1 && make install_sw > /build/openssl/install.log 2>&1" \
    || { say "FAILED: OpenSSL build; see $T/*.log"; exit 1; }
fi
# CMake 3.16 looks for it under lib/.
[ -e "$R/usr/local/openssl3/lib" ] || ln -s lib64 "$R/usr/local/openssl3/lib"
# 20.04's own OpenSSL headers out of the way, so the build cannot pick them.
chroot "$R" /bin/bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -qq remove -y libssl-dev > /dev/null 2>&1 || true'
say "glibc $(chroot "$R" ldd --version | head -1 | grep -o '[0-9.]*$'), $(chroot "$R" cmake --version | head -1)"
say DONE
