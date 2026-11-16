#!/bin/bash
# ZestSSH's Linux packages and repositories (apt
# install zestssh, .deb and .rpm; no install script, no Flathub).
#
#   build_linux_repo.sh <version> <build>
#
# From the released tarball on the Desktop (ZestSSH-<ver>-linux-x64.tar.gz):
#   1. a .deb (zestssh_<ver>_amd64.deb) and an .rpm (zestssh-<ver>-<build>.x86_64.rpm,
#      signed), both installing to /opt/zestssh with /usr/bin/zestssh, the menu
#      entry and the icon;
#   2. the apt repository (suite stable, component main, amd64) and the dnf
#      repository, kept in ~/zestssh-linux-repo so each release adds to them,
#      their metadata signed with the ZestSSH packages key
#      (712D3E44F635E3328F2924F3B5819DA4B34610B8);
#   3. the public key as zestssh.asc and zestssh.gpg, and zestssh.repo for dnf.
# ~/zestssh-linux-repo/public is what is published under linux/ on the website.
#
# Places, each from the environment when set:
#   ZEST_PACKAGES_GNUPGHOME  the GnuPG home that holds the packages key (required)
#   ZEST_PACKAGES_PASSFILE   the file with that key's passphrase (required)
#   DESK_OUT                 the folder with the tarball: else the Windows account's Desktop
#                            (OneDrive's when it keeps the Desktop), found through WSL's interop
#   ZEST_LINUX_REPO          the repository tree (default ~/zestssh-linux-repo/public)
# The two required ones may be kept in ~/.config/zestssh/linux-release.env (not in this
# repository), which is read when it exists.
set -euo pipefail
VER="$1"; BUILD="$2"
FPR=712D3E44F635E3328F2924F3B5819DA4B34610B8
say() { echo "[$(date +%H:%M:%S)] $*"; }
LOCAL_ENV="${ZEST_LINUX_RELEASE_ENV:-$HOME/.config/zestssh/linux-release.env}"
# shellcheck disable=SC1090
[ -f "$LOCAL_ENV" ] && . "$LOCAL_ENV"
[ -n "${ZEST_PACKAGES_GNUPGHOME:-}" ] || { say "FAILED: set ZEST_PACKAGES_GNUPGHOME (or put it in $LOCAL_ENV)"; exit 1; }
[ -n "${ZEST_PACKAGES_PASSFILE:-}" ] || { say "FAILED: set ZEST_PACKAGES_PASSFILE (or put it in $LOCAL_ENV)"; exit 1; }
export GNUPGHOME="$ZEST_PACKAGES_GNUPGHOME"
PASSFILE="$ZEST_PACKAGES_PASSFILE"
if [ -z "${DESK_OUT:-}" ]; then
  WIN_PROFILE=$(/mnt/c/Windows/System32/cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r' || true)
  WIN_PROFILE=${WIN_PROFILE:+$(wslpath -u "$WIN_PROFILE" 2>/dev/null || true)}
  if [ -n "$WIN_PROFILE" ] && [ -d "$WIN_PROFILE/OneDrive/Desktop" ]; then DESK_OUT="$WIN_PROFILE/OneDrive/Desktop"
  elif [ -n "$WIN_PROFILE" ]; then DESK_OUT="$WIN_PROFILE/Desktop"; fi
fi
[ -n "${DESK_OUT:-}" ] || { say "FAILED: no tarball folder; set DESK_OUT"; exit 1; }
TARBALL="$DESK_OUT/ZestSSH-$VER-linux-x64.tar.gz"
REPO="${ZEST_LINUX_REPO:-$HOME/zestssh-linux-repo/public}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sign() { gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSFILE" --local-user "$FPR" "$@"; }

[ -f "$TARBALL" ] || { say "FAILED: no $TARBALL"; exit 1; }
mkdir -p "$REPO/apt/pool/main/z/zestssh" "$REPO/apt/dists/stable/main/binary-amd64" "$REPO/rpm"

# ── The tree both packages install ──
ROOT="$WORK/root"
mkdir -p "$ROOT/opt/zestssh" "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/usr/share/pixmaps"
tar -xzf "$TARBALL" -C "$ROOT/opt/zestssh"
rm -f "$ROOT/opt/zestssh/install-desktop-entry.sh"   # the package adds the entry itself
[ -x "$ROOT/opt/zestssh/zestssh" ] || { say "FAILED: no zestssh in the tarball"; exit 1; }
ln -s /opt/zestssh/zestssh "$ROOT/usr/bin/zestssh"
cp "$ROOT/opt/zestssh/data/flutter_assets/assets/ZestSSH.png" "$ROOT/usr/share/pixmaps/zestssh.png"
cat > "$ROOT/usr/share/applications/com.affluentlabs.zestssh.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZestSSH
Comment=The Fresh SSH Client
Exec=/opt/zestssh/zestssh %u
Icon=zestssh
Terminal=false
Categories=Network;RemoteAccess;
MimeType=x-scheme-handler/zestssh;
StartupWMClass=com.affluentlabs.zestssh
EOF
SIZE_KB=$(du -sk "$ROOT/opt" | cut -f1)
# The newest glibc the app's files ask for, which the .deb then needs (the .rpm finds its own). Built on
# Ubuntu 20.04 since 3.2.2 (tool/linux/build_linux_focal.sh), it is 2.29 or so; on 26.04 it was 2.38.
GLIBC_MIN=$(for f in "$ROOT/opt/zestssh/zestssh" "$ROOT"/opt/zestssh/lib/*.so; do
  objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*'; done | sed 's/GLIBC_//' | sort -u -V | tail -1)
[ -n "$GLIBC_MIN" ] || { say "FAILED: no glibc version found in the bundle"; exit 1; }
say "needs glibc $GLIBC_MIN or later"

# ── .deb ──
DEB="$WORK/deb"
cp -a "$ROOT" "$DEB"
mkdir -p "$DEB/DEBIAN"
# Recommends: xdg-utils opens links; zenity or kdialog draws every file
# dialog (file_picker on Linux runs one of them: without either, Save and
# Open did nothing); libglib2.0-bin brings gdbus and gio, which the tray and
# the keyring's checks call (found in a review before 4.0).
cat > "$DEB/DEBIAN/control" <<EOF
Package: zestssh
Version: $VER
Architecture: amd64
Maintainer: Affluent Labs LLC <support@zestssh.com>
Installed-Size: $SIZE_KB
Depends: libc6 (>= $GLIBC_MIN), libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libsecret-1-0, libayatana-appindicator3-1, libstdc++6, zlib1g, libzstd1, libasound2t64 | libasound2
Recommends: xdg-utils, zenity | kdialog, libglib2.0-bin
Section: net
Priority: optional
Homepage: https://zestssh.com
Description: The fresh SSH client
 ZestSSH is an SSH client for every device you own: hosts, terminal, files,
 keys and tunnels in one app, with free end-to-end encrypted sync.
EOF
cat > "$DEB/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
exit 0
EOF
cp "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/postrm"
chmod 755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/postrm"
DEBFILE="zestssh_${VER}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$DEB" "$WORK/$DEBFILE" >/dev/null
cp "$WORK/$DEBFILE" "$REPO/apt/pool/main/z/zestssh/"
say "deb: $DEBFILE ($(stat -c%s "$WORK/$DEBFILE") bytes)"

# ── .rpm ──
RPMTOP="$WORK/rpmbuild"
# Every library the app brings (lib/*.so*), escaped for rpm's exclude: none
# of them may be asked of the system.
BUNDLED=$(cd "$ROOT/opt/zestssh/lib" && ls | sed 's/[.]/\\\\./g' | paste -sd'|')
mkdir -p "$RPMTOP"/{SPECS,BUILD,RPMS,BUILDROOT}
cat > "$RPMTOP/SPECS/zestssh.spec" <<EOF
Name: zestssh
Version: $VER
Release: $BUILD
Summary: The fresh SSH client
# GPL-3.0-only, with the additional permission in LICENSE-EXCEPTION.txt (rpm takes an SPDX name).
License: GPL-3.0-only
URL: https://zestssh.com
Vendor: Affluent Labs LLC
Packager: Affluent Labs LLC <support@zestssh.com>
ExclusiveArch: x86_64
AutoReqProv: yes
# As the .deb recommends: a file dialog program, and gdbus and gio.
Recommends: zenity, glib2
# What the app brings in /opt/zestssh/lib is its own: nothing else may take it
# as provided, and nothing in it is asked of the system.
%global __provides_exclude_from ^/opt/zestssh/.*\$
%global __requires_exclude ^($BUNDLED)
%global debug_package %{nil}
%global __strip /bin/true
%global _build_id_links none

%description
ZestSSH is an SSH client for every device you own: hosts, terminal, files,
keys and tunnels in one app, with free end-to-end encrypted sync.

%install
cp -a $ROOT/. %{buildroot}/

%post
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true

%files
/opt/zestssh
/usr/bin/zestssh
/usr/share/applications/com.affluentlabs.zestssh.desktop
/usr/share/pixmaps/zestssh.png
EOF
rpmbuild --quiet --define "_topdir $RPMTOP" -bb "$RPMTOP/SPECS/zestssh.spec" >/dev/null 2>"$WORK/rpmbuild.log" || { tail -20 "$WORK/rpmbuild.log"; say "FAILED: rpmbuild"; exit 1; }
RPMFILE="zestssh-$VER-$BUILD.x86_64.rpm"
cp "$RPMTOP/RPMS/x86_64/$RPMFILE" "$REPO/rpm/"
# Sign the package itself (dnf checks it with gpgcheck=1).
rpm --define "_gpg_name $FPR" --define "_gpg_path $GNUPGHOME" \
    --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file $PASSFILE" \
    --addsign "$REPO/rpm/$RPMFILE" >/dev/null
say "rpm: $RPMFILE ($(stat -c%s "$REPO/rpm/$RPMFILE") bytes, signed)"
rpm -qp --requires "$REPO/rpm/$RPMFILE" 2>/dev/null | grep -v "^rpmlib\|^/bin/sh" | tr '\n' ' ' | sed 's/^/[requires] /'; echo

# ── Keys and the dnf .repo file ──
gpg --armor --export "$FPR" > "$REPO/zestssh.asc"
gpg --export "$FPR" > "$REPO/zestssh.gpg"
cat > "$REPO/rpm/zestssh.repo" <<'EOF'
[zestssh]
name=ZestSSH
baseurl=https://zestssh.com/linux/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://zestssh.com/linux/zestssh.asc
EOF

# ── apt metadata ──
cd "$REPO/apt"
apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
gzip -9kf dists/stable/main/binary-amd64/Packages
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="ZestSSH" \
  -o APT::FTPArchive::Release::Label="ZestSSH" \
  -o APT::FTPArchive::Release::Suite="stable" \
  -o APT::FTPArchive::Release::Codename="stable" \
  -o APT::FTPArchive::Release::Architectures="amd64" \
  -o APT::FTPArchive::Release::Components="main" \
  -o APT::FTPArchive::Release::Description="ZestSSH by Affluent Labs LLC" \
  release dists/stable > "$WORK/Release"
mv "$WORK/Release" dists/stable/Release
sign --clearsign -o dists/stable/InRelease dists/stable/Release
sign -abs -o dists/stable/Release.gpg dists/stable/Release
say "apt: $(grep -c '^Package:' dists/stable/main/binary-amd64/Packages) package version(s), signed"

# ── dnf metadata ──
cd "$REPO/rpm"
createrepo_c --update --quiet .
sign --detach-sign --armor -o repodata/repomd.xml.asc repodata/repomd.xml
say "dnf: $(ls *.rpm | wc -l) package version(s), repomd signed"

# ── Check both signatures as a client would ──
gpg --verify "$REPO/apt/dists/stable/InRelease" >/dev/null 2>&1 && say "check: InRelease signature good"
gpg --verify "$REPO/rpm/repodata/repomd.xml.asc" "$REPO/rpm/repodata/repomd.xml" >/dev/null 2>&1 && say "check: repomd signature good"
rpm --define "_dbpath $WORK/rpmdb" --initdb && rpm --define "_dbpath $WORK/rpmdb" --import "$REPO/zestssh.asc" \
  && rpm --define "_dbpath $WORK/rpmdb" -K "$REPO/rpm/$RPMFILE" | sed 's/^/check: /'
say DONE
